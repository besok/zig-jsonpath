# zig-jsonpath

A Zig implementation of JSONPath, fully compliant with [RFC 9535](https://www.rfc-editor.org/rfc/rfc9535.html).

## Examples

Given the json

```json
{
  "store": {
    "book": [
      {
        "category": "reference",
        "author": "Nigel Rees",
        "title": "Sayings of the Century",
        "price": 8.95
      },
      {
        "category": "fiction",
        "author": "Evelyn Waugh",
        "title": "Sword of Honour",
        "price": 12.99
      },
      {
        "category": "fiction",
        "author": "Herman Melville",
        "title": "Moby Dick",
        "isbn": "0-553-21311-3",
        "price": 8.99
      },
      {
        "category": "fiction",
        "author": "J. R. R. Tolkien",
        "title": "The Lord of the Rings",
        "isbn": "0-395-19395-8",
        "price": 22.99
      }
    ],
    "bicycle": {
      "color": "red",
      "price": 19.95
    }
  },
  "expensive": 10
}
```

| JsonPath                                | Result                                                       |
|-----------------------------------------|:-------------------------------------------------------------|
| `$.store.book[*].author`                | The authors of all books                                     |
| `$..book[?@.isbn]`                      | All books with an ISBN number                                |
| `$.store.*`                             | All things, both books and bicycles                          |
| `$..author`                             | All authors                                                  |
| `$.store..price`                        | The price of everything                                      |
| `$..book[2]`                            | The third book                                               |
| `$..book[-2]`                           | The second to last book                                      |
| `$..book[0,1]`                          | The first two books                                          |
| `$..book[:2]`                           | All books from index 0 (inclusive) until index 2 (exclusive) |
| `$..book[1:2]`                          | All books from index 1 (inclusive) until index 2 (exclusive) |
| `$..book[-2:]`                          | Last two books                                               |
| `$..book[2:]`                           | Book number two from tail                                    |
| `$.store.book[?@.price < 10]`           | All books in store cheaper than 10                           |
| `$..book[?@.price <= $.expensive]`      | All books in store that are not "expensive"                  |
| `$..*`                                  | Give me every thing                                          |

## Library Usage

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .zig_jsonpath = .{
        .url = "https://github.com/your-org/zig-jsonpath/archive/<commit>.tar.gz",
        .hash = "<hash>",
    },
},
```

And in `build.zig`:

```zig
const jsonpath = b.dependency("zig_jsonpath", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("jsonpath", jsonpath.module("zig_jsonpath"));
```

### One-shot query from strings

The simplest API — parse the JSON document and run a query in one call:

```zig
const jsonpath = @import("jsonpath");

const result = try jsonpath.query_str(
    \\{"store":{"book":[{"price":8.95},{"price":12.99}]}}
    , "$.store.book[?@.price < 10]", allocator);
defer result.deinit();

for (result.results) |item| {
    std.debug.print("{s}: {f}\n", .{ item.path, std.json.fmt(item.json.*, .{}) });
}
```

### Reuse a parsed query across multiple documents

Parse the query once, run it against many documents:

```zig
const jsonpath = @import("jsonpath");

var q = try jsonpath.parser.parse("$.store.book[?@.price < 10]", allocator);
defer q.deinit(allocator);

for (documents) |source| {
     
    // doc is std.json.Parsed(std.json.Value) — owns the parsed JSON
    var result = try jsonpath.query.perform(source,q allocator);
    defer result.deinit();

    for (result.results) |item| {
        std.debug.print("{s}: {f}\n", .{ item.path, std.json.fmt(item.json.*, .{}) });
    }
}
```

### Working with results

`JsonPathResult` contains a slice of `JsonPointer` values, each holding a pointer into the original document and the path string:

```zig
const result = try jsonpath.query_str(source, "$.store.book[*].author", allocator);
defer result.deinit();

for (result.results) |item| {
    // item.path — e.g. "$['store']['book'][0]['author']"
    // item.json — *std.json.Value pointing into the parsed document
    std.debug.print("path={s} value={f}\n", .{
        item.path,
        std.json.fmt(item.json.*, .{}),
    });
}
```

### Supported selectors

| Selector          | Example              | Description                              |
|-------------------|----------------------|------------------------------------------|
| Root              | `$`                  | The root node                            |
| Name              | `$.foo`              | Child by name                            |
| Index             | `$[0]`               | Array element by index                   |
| Negative index    | `$[-1]`              | Array element from end                   |
| Wildcard          | `$[*]`               | All children                             |
| Slice             | `$[1:3]`             | Array slice                              |
| Multiple          | `$['a','b']`         | Multiple selectors                       |
| Descendant        | `$..foo`             | Recursive descent                        |
| Filter            | `$[?@.price < 10]`   | Filter by expression                     |

### Supported filter functions

| Function    | Example                        | Description                                      |
|-------------|--------------------------------|--------------------------------------------------|
| `length()`  | `$[?length(@.name) > 5]`       | Length of string, array, or object               |
| `count()`   | `$[?count(@.tags.*) > 1]`      | Number of nodes in a node list                   |
| `value()`   | `$[?value(@.x) == 1]`          | Value of a singular query                        |
| `match()`   | `$[?match(@.name, 'foo.*')]`   | Full string match against a regex pattern        |
| `search()`  | `$[?search(@.name, 'foo')]`    | Substring search against a regex pattern         |

### Debug tracing

Enable query tracing at build time:

```bash
zig build test -Ddebug-query=true
```

This prints detailed per-step cursor state for every query operation, useful for debugging complex filter expressions.

## Compliance

The library targets full compliance with RFC 9535. Run the compliance suite:

```bash
zig build compliance
```

## Build options

| Option            | Default | Description                        |
|-------------------|---------|------------------------------------|
| `-Ddebug-query`   | `false` | Enable query debug tracing         |
| `-Dfilter`        | none    | Filter tests by name               |

```bash
zig build test                                              # run all tests
zig build test -Dfilter="filter match function basic"       # run one test
zig build test -Ddebug-query=true                          # all tests with debug
zig build compliance                                        # compliance suite
zig build check                                             # unit tests + compliance
```