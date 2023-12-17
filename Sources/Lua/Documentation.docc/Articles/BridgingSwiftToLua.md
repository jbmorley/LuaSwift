# Bridging a Swift object into Lua

## Overview

Any Swift type can be made accessible from Lua. The process of defining what fields, methods etc should be exposed is referred to as "bridging". There are two parts to the process: firstly, defining the Lua _metatable_ for the type; and secondly, making specific value(s) of that type available to the Lua runtime, which is often referred to as "pushing" due to the first step always being to push the value on to the Lua stack. Each of these parts are covered below; before that is a brief description of how bridging is implemented.

### Bridging implementation

Basic Swift types are pushed by value - that is to say they are copied and converted to the equivalent Lua type. A Swift `String` is made available to Lua by converting it to a Lua `string`, a Swift `Array` is converted to a Lua `table`, etc.

Bridged values on the other hand are represented in Lua using the `userdata` Lua type, which from the Swift side behave as if there was an assignment like `var userdata: Any = myval`. So for classes, the `userdata` holds an additional reference to the object, and for structs the `userdata` holds a value copy of it. A `__gc` metamethod is automatically generated, which means that when the `userdata` is garbage collected by Lua, the equivalent of `userdata = nil` is performed.

As described so far, the `userdata` plays nicely with Lua and Swift object lifetimes and memory management, but does not allow you to do anything useful with it from Lua other than controlling when it goes out of scope. This is where defining a metatable comes in.

### Defining a metatable

A metatable is how you define what Swift properties and methods are accessible or callable from Lua. More information about what metatables are is available [in the Lua manual](https://www.lua.org/manual/5.4/manual.html#2.4). You must define a metatable for each type you intend to bridge into Lua - the Swift runtime is not dynamic enough to do much of this automatically. The way you do this is by making a call to ``Lua/Swift/UnsafeMutablePointer/registerMetatable(for:fields:metafields:)`` passing in the Swift type in question, the fields you want to make visible in Lua, and any custom metamethods you want to define.

For example, supposing we have a class called `Foo`, and we want to be able to make instances of this class available to Lua so that Lua code can call the `bar()` method:

```swift
class Foo {
    var prop = "example"

    public func bar() {
        print("bar() was called!")
    }
}
```

We need to therefore call `registerMetatable()` with `fields` containing an ``LuaClosure`` called `bar` (which will become the Lua `bar()` member function) which calls the Swift `bar()` function. Here we are assuming the Lua API should be a member function called as `foo:bar()`, therefore the `Foo` userdata will be argument 1. We recover the original Swift `Foo` instance by calling ``Lua/Swift/UnsafeMutablePointer/touserdata(_:)``. We also use ``Lua/Swift/UnsafeMutablePointer/checkArgument(_:)`` to raise a Lua error if the arguments were not correct.

Since we are not making any customizations to the metatable (other than to add fields) we can omit the `metafields:` argument entirely.

```swift
L.registerMetatable(for: Foo.self, fields: [
    "bar": .closure { L in
        // (1) Convert our Lua arguments back to Swift values...
        let foo: Foo = try L.checkArgument(1)
  
        // ... (2) make the call into Swift ...
        foo.bar()
  
        // ... (3) and return any results (we always return `nil` here)
        L.pushnil()
        return 1
    }
])
```

The above has quite a bit of boilerplate in the definition of `"bar"`, which can be avoided in common cases by using `.memberfn` instead of `.closure`, which uses type inference to generate suitable boilerplate. `.memberfn` can handle most argument and return types providing they can be used with `tovalue()` and `push(any:)`. The following much more concise code behaves identically to the previous example:

```swift
L.registerMetatable(for: Foo.self, fields: [
    "bar": .memberfn { $0.bar() }
])
```

In a `.memberfn` closure, `$0` refers the userdata value (here, the `Foo` instance). Arguments use `$1`, `$2` etc. Arguments are type-checked using using `L.checkArgument<ArgumentType>()`.

Anything which exceeds the type inference abilities of `.memberfn` can always be written explicitly using `.closure`. The full list of helpers that can be used to define fields is defined in ``UserdataField``.

### Pushing values into Lua

Having defined a metatable for our type, we can use ``Lua/Swift/UnsafeMutablePointer/push(userdata:toindex:)`` or ``Lua/Swift/UnsafeMutablePointer/push(any:toindex:)`` to push instances of it on to the Lua stack, at which point we can assign it to a variable just like any other Lua value. Using the example `Foo` class described above, and assuming our Lua code expects a single global value called `foo` to be defined, we could use ``Lua/Swift/UnsafeMutablePointer/setglobal(name:)``:

```swift
let foo = Foo()
L.push(userdata: foo)
L.setglobal(name: "foo")
```

This could be simplified using the `setglobal` overload that takes a `value` combined with the Pushable helper function ``Pushable/userdata(_:)``:

```swift
L.setglobal(name: "foo", value: .userdata(Foo()))
```

In Lua, there is now a global value called `foo` which has a `bar()` method that can be called on it:

```lua
foo:bar()
-- Above call results in "bar() was called!" being printed
```

To simplify pushing even further, `Foo` could be made directly `Pushable` for example via an extension:

```swift
extension Foo: Pushable {
    public func push(onto L: LuaState) {
        L.push(userdata: self)
    }
}

// ...

L.setglobal(name: "foo", value: Foo())
```

### More advanced metatables

The examples used above defined only a very simple metatable which bridged a single member function. One obvious addition would be to bridge properties, as well as functions. This can be done in a similar way to `.memberfn`, by using `.property`. Here is an example which exposes both `Foo.bar()` and `Foo.prop`:

```swift
L.registerMetatable(for: Foo.self, fields: [
    "bar": .memberfn { $0.bar() },
    "prop": .property { $0.prop },
])
```

`.property` may also be used to define read-write properties, by specifying both `get:` and `set:`:

```swift
L.registerMetatable(for: Foo.self, fields: [
    "prop": .property(get: { $0.prop }, set: { $0.prop = $1 }),
])
```

To customize the bridging above and beyond adding fields to the userdata, we can pass in custom metafields. For example, to make `Foo` callable and closable (see [to-be-closed variables](https://www.lua.org/manual/5.4/manual.html#3.3.8), we'd add `.call` and `.close` entries to `metafields`:

```swift
L.registerMetatable(for: Foo.self, metafields: [
    .call: .closure { L in
        print("I have no idea what this should do")
        return 0
    },
    .close: .closure { L in
        let foo: Foo = try L.checkArgument(1)
        // Do whatever is appropriate to foo here, eg calling a close() function
        return 0
    }
])
```

Metafield names are referred to using constants like `.call` instead of strings like `"__call"` as in the C and Lua APIs, to prevent typographical mistakes and to disallow the setting of metafields which are managed by the LuaSwift framework (such as `__name` and `__gc`) or make no sense for userdatas (such as `__mode`).

Note we cannot use `.memberfn` in the definition of `metafields`, only `.function` and `.closure`. Some metafields do however support being auto-generated by specifying `.synthesize`, and `.close` is one of them. To take best advantage of this, the type needs to conform to ``Closable``:

```swift
class Foo: Closable {
    func close() {
        // Do whatever
    }
    // .. rest of definition as before
}

L.registerMetatable(for: Foo.self, metafields: [
    .close: .synthesize // This will call Foo.close()
])
```

This will result in a `__close` metafield which calls the `Closable` `close()` function. If the type does not conform to `Closable`, then `.close: .synthesize` may still be specified, in which case the Lua-side reference to the Swift value will be nilled when `__close` is called.

Under the hood, the implementation of support for `fields` uses a synthesized `.index` metafield, therefore if `fields` is non-nil then `.index: .synthesize` is assumed. It is therefore an error for `.index` to be set to something other than `.synthesize` if `fields` is specified (omitting it is allowed, however). `.newindex` behaves similarly if there are any read-write properties defined in `fields`.

Explicitly providing a `.index` metafield is the most flexible option, but means we must handle all functions, properties and type conversions manually. The following would be one way to define such a metafield for the example `Foo` class defined earlier:

```swift
L.registerMetatable(for: Foo.self, metafields: [
    .call: .closure { L in
        print("I have no idea what this should do")
        return 0
    },
    .close: .synthesize,
    .index: .closure { L in
        let foo: Foo = try L.checkArgument(1)
        let memberName: String = try L.checkArgument(2)
        switch memberName {
        case "bar":
            // Simplifying, given there are no arguments or results to worry about
            L.push(closure: { foo.bar() })
        case "prop":
            L.push(foo.prop)
        default:
            L.pushnil()
        }
        return 1
    },
    .newindex: .closure { L in
        let foo: Foo = try L.checkArgument(1)
        let memberName: String = try L.checkArgument(2)
        switch memberName {
        case "prop":
            foo.prop = L.checkArgument(3)
        default:
            throw L.argumentError(2, "no set function defined for property \(memberName)")
        }
        return 0
    }
])
```

For this simple example, the explicit `.index` metafield may look simpler than using `fields` and the synthesized `.index`. When there are many functions with many argument types to convert, `fields` and `.memberfn`/`.staticfn` may be preferable.

The examples throughout this article lean heavily on Swift's convenience syntax for conciseness. For example the following two calls are equivalent:

```swift
L.registerMetatable(for: Foo.self, fields: [
    "prop": .property { $0.prop }
])

L.registerMetatable(for: Foo.self, fields: [
    "prop": UserdataField.property(get: { (obj: Foo) -> String in
        return obj.prop
    })
])
```

## Member and non-member functions

There are two ways to define convenience function bindings in `fields`: using `.memberfn` and using `.staticfn`. Both accept a variable number of arguments and automatically perform type conversion on them. The difference is how they are expected to be called from Lua and what `$0` is bound to in the closure as a result.

`.memberfn` is for Lua functions which will be called using member function syntax, `value:fnname()` where the `foo` object is (under the hood) passed in as the first argument. `$0` is always bound to the `Foo` instance (or whatever type we're defining the metatable for).

`.staticfn` is for non-member functions, called with `value.fnname()`, where the object is _not_ the first argument. In the `staticfn` closure, `$0` is not bound to the `Foo` instance, and is instead just the first argument passed to the Lua function, if any. For example:

```swift
class Foo {
    static func baz(_: Bool) {
        // Do whatever
    }
    // .. rest of definition as before
}

L.registerMetatable(for: Foo.self, fields: [
    "baz": .staticfn { Foo.baz($0) },
])

// Means we can do foo.baz(true) in Lua
```

If you want the Lua code to be callable without using member syntax, but for those functions to be able to call `Foo` member functions, you must define the `.index` metafield explicitly rather than using `fields:`, so that you can recover the `foo` instance from the 1st index argument instead (as the example `.index` implementation above does).

## Default metatables

In addition to defining metatables for individual types, you can define a default metatable using ``Lua/Swift/UnsafeMutablePointer/registerDefaultMetatable(metafields:)`` which is used as a fallback for any type that has not had a call to `registerMetatable()`. This is useful in situations where many related-but-distinct types of value may be pushed and it is easier to provide a single implementation of eg the `.index` metamethod and introspect the value there, than it is to call `registerMetatable()` with lots of different types.

Because the default metatable is not bound to a specific type, `fields` cannot be configured in the call to `registerDefaultMetatable()`, only `metafields`.

## See Also

- ``Lua/Swift/UnsafeMutablePointer/registerMetatable(for:fields:metafields:)``
- ``Lua/Swift/UnsafeMutablePointer/registerDefaultMetatable(metafields:)``
- ``UserdataField``
- ``MetafieldName``
- ``MetafieldValue``