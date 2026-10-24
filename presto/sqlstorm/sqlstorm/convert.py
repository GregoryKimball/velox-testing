# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION.
# SPDX-License-Identifier: Apache-2.0

"""Converts SQLStorm PostgreSQL queries to Presto SQL.

sqlglot does the dialect translation. The rewrites in this module patch the cases
where sqlglot's Presto output is not accepted by Presto. Only rewrites that preserve
the query's semantics are applied; queries that need anything approximate are
reported as unsupported instead.
"""

import re
from dataclasses import dataclass

import sqlglot
from sqlglot import exp

# Every StackOverflow table has a non-null integer primary key named Id.
BASE_TABLES = {
    "posthistorytypes", "linktypes", "posttypes", "closereasontypes", "votetypes", "users",
    "badges", "posts", "comments", "posthistory", "postlinks", "tags", "votes",
}  # fmt: skip
TIMESTAMP_COLUMNS = {
    "creationdate", "lastaccessdate", "date", "lasteditdate", "lastactivitydate", "closeddate",
    "communityowneddate",
}  # fmt: skip
TIMESTAMP_LITERAL = re.compile(r"^\d{4}-\d{2}-\d{2}([ T]\d{2}:\d{2}(:\d{2}(\.\d+)?)?)?$")


@dataclass
class Conversion:
    ok: bool
    sql: str | None = None
    reason: str | None = None


class Unsupported(Exception):
    pass


def convert(postgres_sql):
    try:
        statements = [s for s in sqlglot.parse(postgres_sql, read="postgres") if s is not None]
    except sqlglot.errors.ParseError as e:
        return Conversion(False, reason=f"parse: {first_line(e)}")
    if len(statements) != 1:
        return Conversion(False, reason=f"expected 1 statement, found {len(statements)}")

    try:
        tree = rewrite(statements[0])
        presto_sql = tree.sql(dialect="presto", unsupported_level=sqlglot.ErrorLevel.RAISE)
    except Unsupported as e:
        return Conversion(False, reason=f"unsupported: {e}")
    except sqlglot.errors.UnsupportedError as e:
        return Conversion(False, reason=f"sqlglot: {first_line(e)}")
    return Conversion(True, sql=presto_sql)


def rewrite(tree):
    reject_unsupported(tree)
    for rule in (
        rewrite_string_to_array,
        rewrite_lateral_unnest,
        rewrite_epoch_of_difference,
        rewrite_count_of_table_alias,
        rewrite_fetch_to_limit,
        cast_timestamp_literals,
        add_functionally_dependent_group_by,
    ):
        tree = rule(tree)
    return tree


def reject_unsupported(tree):
    for with_ in tree.find_all(exp.With):
        if with_.args.get("recursive"):
            raise Unsupported("recursive CTE")
    for func in tree.find_all(exp.Anonymous):
        if func.name.lower() == "age":
            raise Unsupported("AGE returns a calendar interval")


def rewrite_string_to_array(tree):
    """string_to_array(s, d) -> IF(s = '', ARRAY[], SPLIT(s, d)); Postgres returns {} for ''."""
    for node in list(tree.find_all(exp.StringToArray)):
        delimiter = node.expression
        if node.args.get("null") or not (isinstance(delimiter, exp.Literal) and delimiter.is_string and delimiter.this):
            raise Unsupported("string_to_array without a non-empty literal delimiter")
        value = node.this
        node.replace(
            exp.If(
                this=exp.EQ(this=value.copy(), expression=exp.Literal.string("")),
                true=exp.Array(expressions=[]),
                false=exp.Split(this=value.copy(), expression=delimiter.copy()),
            )
        )
    return tree


def lateral_unnest_parts(lateral):
    """Returns (array expression, column name) for the two lateral unnest shapes, else None."""
    alias = lateral.args.get("alias")
    if alias is None:
        return None
    source = lateral.this
    if isinstance(source, exp.Unnest) and len(source.expressions) == 1:
        columns = alias.columns
        column = columns[0].name if len(columns) == 1 else alias.name
        return source.expressions[0], column
    if isinstance(source, exp.Subquery) and isinstance(source.this, exp.Select):
        select = source.this
        if len(select.expressions) != 1 or any(select.args.get(k) for k in ("from_", "where", "group", "joins")):
            return None
        projection = select.expressions[0]
        if isinstance(projection, exp.Alias) and isinstance(projection.this, (exp.Explode, exp.Unnest)):
            inner = projection.this
            array = inner.this if isinstance(inner, exp.Explode) else inner.expressions[0]
            return array, projection.alias
    return None


def rewrite_lateral_unnest(tree):
    """JOIN LATERAL unnest(...) -> CROSS JOIN UNNEST(...); Presto only supports UNNEST on a cross join.

    LEFT joins keep a NULL row for an empty or NULL array, matching Postgres.
    """
    for join in list(tree.find_all(exp.Join)):
        lateral = join.this
        if not isinstance(lateral, exp.Lateral):
            continue
        parts = lateral_unnest_parts(lateral)
        if parts is None:
            continue
        array, column = parts
        on = join.args.get("on")
        trivially_true = on is None or (isinstance(on, exp.Boolean) and on.this)
        side = (join.side or "").upper()
        array = array.copy()
        if side == "LEFT":
            if not trivially_true:
                raise Unsupported("LEFT JOIN LATERAL unnest with a join condition")
            array = exp.If(
                this=exp.GT(this=exp.ArraySize(this=array.copy()), expression=exp.Literal.number(0)),
                true=array,
                false=exp.Array(expressions=[exp.Null()]),
            )
        elif side:
            raise Unsupported(f"{side} JOIN LATERAL unnest")
        elif not trivially_true:
            select = join.parent_select
            select.where(on.copy(), copy=False)

        unnest = exp.Unnest(
            expressions=[array],
            alias=exp.TableAlias(this=exp.to_identifier(lateral.alias), columns=[exp.to_identifier(column)]),
        )
        join.replace(exp.Join(this=unnest, kind="CROSS"))
    return tree


def rewrite_epoch_of_difference(tree):
    """EXTRACT(EPOCH FROM (a - b)) -> DATE_DIFF('millisecond', b, a) / 1000.0 (the data has ms precision)."""
    for node in list(tree.find_all(exp.Extract)):
        if node.name.upper() != "EPOCH":
            continue
        inner = node.expression.unnest()
        if not isinstance(inner, exp.Sub):
            continue
        diff = exp.Anonymous(
            this="DATE_DIFF",
            expressions=[exp.Literal.string("millisecond"), inner.expression.copy(), inner.this.copy()],
        )
        node.replace(exp.Paren(this=exp.Div(this=diff, expression=exp.Literal.number("1000.0"))))
    return tree


def table_aliases(select):
    """Maps lowercase alias -> lowercase table name for base tables in this SELECT's FROM and JOINs."""
    sources = []
    if select.args.get("from_"):
        sources.append(select.args["from_"].this)
    sources.extend(join.this for join in select.args.get("joins") or [])
    aliases = {}
    for source in sources:
        if isinstance(source, exp.Table) and source.name.lower() in BASE_TABLES:
            aliases[(source.alias or source.name).lower()] = source.name.lower()
    return aliases


def rewrite_count_of_table_alias(tree):
    """COUNT(t) where t is a table alias -> COUNT(t.Id); a row value is NULL only for an unmatched outer join."""
    for count in list(tree.find_all(exp.Count)):
        arg = count.this
        if not isinstance(arg, exp.Column) or arg.table:
            continue
        select = count.parent_select
        while select is not None:
            if arg.name.lower() in table_aliases(select):
                arg.replace(exp.column("id", table=arg.name))
                break
            select = select.parent_select
    return tree


def rewrite_fetch_to_limit(tree):
    for select in tree.find_all(exp.Select):
        fetch = select.args.get("limit")
        if not isinstance(fetch, exp.Fetch):
            continue
        options = fetch.args.get("limit_options")
        if options and (options.args.get("percent") or options.args.get("with_ties")):
            raise Unsupported("FETCH with PERCENT or WITH TIES")
        count = fetch.args.get("count") or exp.Literal.number(1)
        select.set("limit", exp.Limit(expression=count.copy()))
    return tree


def is_timestamp(node):
    node = node.unnest()
    if isinstance(node, exp.Column):
        return node.name.lower() in TIMESTAMP_COLUMNS
    if isinstance(node, (exp.CurrentTimestamp, exp.CurrentDate)):
        return True
    if isinstance(node, exp.Cast):
        return node.to.this in (exp.DataType.Type.TIMESTAMP, exp.DataType.Type.DATE)
    if isinstance(node, (exp.Add, exp.Sub)):
        return is_timestamp(node.this) or is_timestamp(node.expression)
    return False


def is_timestamp_literal(node):
    return isinstance(node, exp.Literal) and node.is_string and TIMESTAMP_LITERAL.match(node.this)


def cast_to_timestamp(literal):
    literal.replace(exp.cast(literal.copy(), exp.DataType.Type.TIMESTAMP))


def cast_timestamp_literals(tree):
    """Casts date-like string literals compared with timestamps, as Postgres does implicitly."""
    for node in list(tree.find_all(exp.EQ, exp.NEQ, exp.GT, exp.GTE, exp.LT, exp.LTE)):
        for a, b in ((node.this, node.expression), (node.expression, node.this)):
            if is_timestamp_literal(a) and is_timestamp(b):
                cast_to_timestamp(a)
    for node in list(tree.find_all(exp.Between)):
        if is_timestamp(node.this):
            for bound in (node.args.get("low"), node.args.get("high")):
                if is_timestamp_literal(bound):
                    cast_to_timestamp(bound)
    for node in list(tree.find_all(exp.In)):
        if is_timestamp(node.this):
            for value in node.expressions:
                if is_timestamp_literal(value):
                    cast_to_timestamp(value)
    for node in list(tree.find_all(exp.Coalesce, exp.Nullif)):
        args = [node.this, *node.expressions] if isinstance(node, exp.Coalesce) else [node.this, node.expression]
        if any(is_timestamp(arg) for arg in args):
            for arg in args:
                if is_timestamp_literal(arg):
                    cast_to_timestamp(arg)
    return tree


def needs_grouping(column, select):
    """True if the column is evaluated per group (not inside an aggregate) directly in this SELECT."""
    node = column
    while node.parent is not None and node is not select:
        parent = node.parent
        if isinstance(node, exp.AggFunc) and not (isinstance(parent, exp.Window) and parent.this is node):
            return False
        if isinstance(parent, (exp.Select, exp.Subquery)) and parent is not select:
            return False
        node = parent
    return node is select


def add_functionally_dependent_group_by(tree):
    """Adds columns that Postgres accepts because they depend on a grouped primary key.

    Postgres lets a query select t.col when t.Id is in GROUP BY and t is a base table
    with primary key Id. Adding t.col to GROUP BY leaves the groups unchanged.
    """
    for select in list(tree.find_all(exp.Select)):
        group = select.args.get("group")
        if not group:
            continue
        aliases = table_aliases(select)
        grouped = {(c.table.lower(), c.name.lower()) for c in group.expressions if isinstance(c, exp.Column)}
        keyed = {table for table, name in grouped if name == "id" and table in aliases}
        if len(aliases) == 1 and ("", "id") in grouped:
            keyed.add("")
        if not keyed:
            continue

        output_names = {e.alias_or_name.lower() for e in select.expressions}
        clauses = [*select.expressions, select.args.get("having"), select.args.get("order")]
        for clause in filter(None, clauses):
            for column in clause.find_all(exp.Column):
                key = (column.table.lower(), column.name.lower())
                if not key[0] and key[1] in output_names and not isinstance(column.parent, exp.Alias):
                    continue
                if key[0] in keyed and key not in grouped and needs_grouping(column, select):
                    group.append("expressions", exp.column(column.name, table=column.table or None))
                    grouped.add(key)
    return tree


def first_line(error):
    return str(error).strip().splitlines()[0][:300]
