// Copyright (c) 2023 Tom Sutcliffe
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

import Foundation
import CLua

/// Provides swift wrappers for the underlying `lua_State` C APIs.
///
/// Due to `LuaState` being an `extension` to `UnsafeMutablePointer<lua_State>`
/// it can be either constructed using the explicit constructor provided, or
/// any C `lua_State` obtained from anywhere can be treated as a `LuaState`
/// Swift object.
///
/// Usage
/// =====
///
///     let state = LuaState(libraries: .all)
///     state.push(1234)
///     assert(state.toint(-1)! == 1234)
public typealias LuaState = UnsafeMutablePointer<lua_State>

public typealias lua_Integer = CLua.lua_Integer

// That this should be necessary is a sad commentary on how string encodings are handled in Swift...
public enum ExtendedStringEncoding {
    case stringEncoding(String.Encoding)
    case cfStringEncoding(CFStringEncodings)
}

public extension String {
    init?(data: Data, encoding: ExtendedStringEncoding) {
        switch encoding {
        case .stringEncoding(let enc):
            self.init(data: data, encoding: enc)
        case .cfStringEncoding(let enc):
            let nsenc =  CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(enc.rawValue))
            if let nsstring = NSString(data: data, encoding: nsenc) {
                self.init(nsstring)
            } else {
                return nil
            }
        }
    }

    func data(using encoding: ExtendedStringEncoding) -> Data? {
        switch encoding {
        case .stringEncoding(let enc):
            return self.data(using: enc)
        case .cfStringEncoding(let enc):
            let nsstring = self as NSString
            let nsenc = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(enc.rawValue))
            return nsstring.data(using: nsenc)
        }
    }
}

fileprivate func moduleSearcher(_ L: LuaState!) -> CInt {
    let pathRoot = L.tostring(lua_upvalueindex(1), encoding: .utf8)!
    let displayPrefix = L.tostring(lua_upvalueindex(2), encoding: .utf8)!
    guard let module = L.tostring(1, encoding: .utf8) else {
        L.pushnil()
        return 1
    }

    let parts = module.split(separator: ".", omittingEmptySubsequences: false)
    let relPath = parts.joined(separator: "/") + ".lua"
    let path = pathRoot + "/" + relPath

    if let data = FileManager.default.contents(atPath: path) {
        var err: CInt = 0
        data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> Void in
            let chars = ptr.bindMemory(to: CChar.self)
            err = luaL_loadbufferx(L, chars.baseAddress, chars.count, "@" + displayPrefix + relPath, "t")
        }
        if err == 0 {
            return 1
        } else {
            return lua_error(L) // errors with the string error pushed by luaL_loadbufferx
        }
    } else {
        L.push("\n\tno resource '\(module)'")
        return 1
    }
}

fileprivate func gcUserdata(_ L: LuaState!) -> CInt {
    let rawptr = lua_touserdata(L, 1)!
    let anyPtr = rawptr.bindMemory(to: Any.self, capacity: 1)
    anyPtr.deinitialize(count: 1)
    return 0
}

fileprivate func tracebackFn(_ L: LuaState!) -> CInt {
    let msg = L.tostring(-1)
    luaL_traceback(L, L, msg, 0)
    return 1
}

/// A Swift enum of the Lua types.
public enum LuaType : CInt {
    // Annoyingly can't use LUA_TNIL etc here because the bridge exposes them as `var LUA_TNIL: CInt { get }`
    // which is not acceptable for an enum (which requires the rawValue to be a literal)
    case nilType = 0 // LUA_TNIL
    case boolean = 1 // LUA_TBOOLEAN
    case lightuserdata = 2 // LUA_TLIGHTUSERDATA
    case number = 3 // LUA_TNUMBER
    case string = 4 // LUA_STRING
    case table = 5 // LUA_TTABLE
    case function = 6 // LUA_TFUNCTION
    case userdata = 7 // LUA_TUSERDATA
    case thread = 8 // LUA_TTHREAD
}

public struct LuaClosureRef {
    let L: LuaState!
    let index: CInt

    public init(L: LuaState!, index: CInt) {
        self.L = L
        self.index = L.absindex(index)
    }
}

// When a nonhashable value is used in a table key
public struct LuaNonHashable: Hashable {
    public let val: Any
    private var ptr: UnsafePointer<Any> {
        get {
            var result: UnsafePointer<Any>?
            withUnsafePointer(to: val) { ptr in
                result = ptr
            }
            return result!
        }
    }
    public init(_ val: Any) {
        self.val = val
    }
    public static func == (lhs: LuaNonHashable, rhs: LuaNonHashable) -> Bool {
        return lhs.ptr == rhs.ptr
    }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(ptr)
    }
}

public struct LuaCallError: Error, Equatable, CustomStringConvertible, LocalizedError {
    public init(_ error: String) {
        self.error = error
    }
    public let error: String
    public var description: String { error }
    public var errorDescription: String? { error }
}

fileprivate var StateRegistryKey: Int = 0

public extension UnsafeMutablePointer where Pointee == lua_State {

    struct Libraries: OptionSet {
        public let rawValue: Int

        public init(rawValue: Int) {
            self.rawValue = rawValue
        }

        public static let package = Libraries(rawValue: 1)
        public static let coroutine = Libraries(rawValue: 2)
        public static let table = Libraries(rawValue: 4)
        public static let io = Libraries(rawValue: 8)
        public static let os = Libraries(rawValue: 16)
        public static let string = Libraries(rawValue: 32)
        public static let math = Libraries(rawValue: 64)
        public static let utf8 = Libraries(rawValue: 128)
        public static let debug = Libraries(rawValue: 256)

        public static let all: Libraries = [ .package, .coroutine, .table, .io, .os, .string, .math, .utf8, .debug]
        public static let safe: Libraries = [ .coroutine, .table, .string, .math, .utf8]
    }

    /// Create a new `LuaState`.
    ///
    /// Note that because `LuaState` is defined as `UnsafeMutablePointer<lua_State>`, the state is _not_ automatically
    /// destroyed when it goes out of scope. You must call `close()`.
    ///
    ///     let state = LuaState(libraries: .all)
    ///
    ///     // is equivalent to:
    ///     let state = luaL_newstate()
    ///     luaL_openlibs(state)
    ///
    /// - Parameter libraries: Which of the standard libraries to open.
    init(libraries: Libraries) {
        self = luaL_newstate()
        requiref(name: "_G", function: luaopen_base)
        openLibraries(libraries)
    }

    /// Destroy and clean up the Lua state.
    ///
    /// Must be the last function called on this `LuaState` pointer.
    func close() {
        lua_close(self)
    }

    private class _State {
        var defaultStringEncoding = ExtendedStringEncoding.stringEncoding(.utf8)
        var metatableDict = Dictionary<String, Array<Any.Type>>()
    }

    private func getState() -> _State {
        if let state = maybeGetState() {
            return state
        }
        let state = _State()
        // Register a metatable for this type with a fixed name to avoid infinite recursion of getMetatableName
        // trying to call getState()
        let mtName = "LuaState._State"
        doRegisterMetatable(typeName: mtName, functions: [:])
        pop() // metatable
        pushuserdata(any: state, metatableName: mtName)
        lua_rawsetp(self, LUA_REGISTRYINDEX, &StateRegistryKey)
        return state
    }

    private func maybeGetState() -> _State? {
        lua_rawgetp(self, LUA_REGISTRYINDEX, &StateRegistryKey)
        var result: _State? = nil
        if let state: _State = touserdata(-1) {
            result = state
        }
        pop()
        return result
    }

    /// Override the default string encoding.
    ///
    /// See `getDefaultStringEncoding()`. If this function is not called, the default encoding is assumed to be UTF-8.
    func setDefaultStringEncoding(_ encoding: ExtendedStringEncoding) {
        getState().defaultStringEncoding = encoding
    }

    /// Get the default string encoding.
    ///
    /// This is the encoding which Lua strings are assumed to be in if an explicit encoding is not supplied when
    /// converting strings to or from Lua, for example when calling `tostring()` or `push(<string>)`. By default, it is
    /// assumed all Lua strings are (or should be) UTF-8.
    func getDefaultStringEncoding() -> ExtendedStringEncoding {
        return maybeGetState()?.defaultStringEncoding ?? .stringEncoding(.utf8)
    }

    func openLibraries(_ libraries: Libraries) {
        if libraries.contains(.package) {
            requiref(name: "package", function: luaopen_package)
        }
        if libraries.contains(.coroutine) {
            requiref(name: "coroutine", function: luaopen_coroutine)
        }
        if libraries.contains(.table) {
            requiref(name: "table", function: luaopen_table)
        }
        if libraries.contains(.io) {
            requiref(name: "io", function: luaopen_io)
        }
        if libraries.contains(.os) {
            requiref(name: "os", function: luaopen_os)
        }
        if libraries.contains(.string) {
            requiref(name: "string", function: luaopen_string)
        }
        if libraries.contains(.math) {
            requiref(name: "math", function: luaopen_math)
        }
        if libraries.contains(.utf8) {
            requiref(name: "utf8", function: luaopen_utf8)
        }
        if libraries.contains(.debug) {
            requiref(name: "debug", function: luaopen_debug)
        }
    }

    /// Configure the directory to look in when loading modules with `require`.
    ///
    /// This replaces the default system search paths, and also disables native
    /// module loading.
    ///
    /// For example `require "foo"` will look for `<path>/foo.lua`, and
    /// `require "foo.bar"` will look for `<path>/foo/bar.lua`.
    ///
    /// - Parameter path: The root directory containing .lua files
    /// - Parameter displayPrefix: Optional string to prefix onto paths shown in
    ///   for example error messages.
    /// - Precondition: The `package` standard library must have been opened.
    func setRequireRoot(_ path: String, displayPrefix: String = "") {
        let L = self
        // Now configure the require path
        guard getglobal("package") == .table else {
            fatalError("Cannot use setRequireRoot if package library not opened!")
        }
        lua_getfield(L, -1, "searchers")
        L.push(path, encoding: .utf8)
        L.push(displayPrefix, encoding: .utf8)
        lua_pushcclosure(L, moduleSearcher, 2) // pops path.path
        lua_rawseti(L, -2, 2) // 2nd searcher is the .lua lookup one
        pushnil()
        lua_rawseti(L, -2, 3) // And prevent 3 from being used
        pushnil()
        lua_rawseti(L, -2, 4) // Ditto 4
        pop(2) // searchers, package
    }

    enum WhatGarbage: CInt {
        case stop = 0
        case restart = 1
        case collect = 2
    }

    private enum MoreGarbage: CInt {
        case count = 3
        case countb = 4
        case isrunning = 9
    }

    func collectgarbage(_ what: WhatGarbage = .collect) {
        lua_gc0(self, what.rawValue)
    }

    func collectorRunning() -> Bool {
        return lua_gc0(self, MoreGarbage.isrunning.rawValue) != 0
    }

    /// Returns the total amount of memory in bytes that the Lua state is using.
    func collectorCount() -> Int {
        return Int(lua_gc0(self, MoreGarbage.count.rawValue)) * 1024 + Int(lua_gc0(self, MoreGarbage.countb.rawValue))
    }

    /// Get the type of the value at the given index.
    ///
    /// - Parameter index: The stack index.
    /// - Returns: the type of the value in the given valid index, or `nil` for a non-valid but acceptable index.
    func type(_ index: CInt) -> LuaType? {
        let t = lua_type(self, index)
        assert(t >= LUA_TNONE && t <= LUA_TTHREAD)
        return LuaType(rawValue: t)
    }

    func typename(_ index: CInt) -> String {
        return String(cString: lua_typename(self, index))
    }

    func absindex(_ index: CInt) -> CInt {
        return lua_absindex(self, index)
    }

    func isnone(_ index: CInt) -> Bool {
        return type(index) == nil
    }

    func isnoneornil(_ index: CInt) -> Bool {
        if let t = type(index) {
            return t == .nilType
        } else {
            return true // ie is none
        }
    }

    func todata(_ index: CInt) -> Data? {
        let L = self
        if type(index) == .string {
            var len: Int = 0
            let ptr = lua_tolstring(L, index, &len)!
            let buf = UnsafeBufferPointer(start: ptr, count: len)
            return Data(buffer: buf)
        } else {
            return nil
        }
    }

    /// Convert the value at the given stack index into a Swift String
    ///
    /// If the value is is not a Lua string and `convert` is false, or if the
    /// string data cannot be converted to the specified encoding, this returns
    /// `nil`. If `convert` is true, `nil` will only be returned if the string
    /// failed to be decoded using `encoding`.
    ///
    /// - Parameter index: The stack index.
    /// - Parameter encoding: The encoding to use to decode the string data, or `nil` to use the default encoding.
    /// - Parameter convert: If true and the value at the given index is not a
    ///   Lua string, it will be converted to a string (invoking `__tostring`
    ///   metamethods if necessary) before being decoded.
    /// - Returns: the value as a String, or `nil` if it could not be converted.
    func tostring(_ index: CInt, encoding: ExtendedStringEncoding? = nil, convert: Bool = false) -> String? {
        let enc = encoding ?? getDefaultStringEncoding()
        if let data = todata(index) {
            return String(data: data, encoding: enc)
        } else if convert {
            var len: Int = 0
            let ptr = luaL_tolstring(self, index, &len)!
            let buf = UnsafeBufferPointer(start: ptr, count: len)
            let result = String(data: Data(buffer: buf), encoding: enc)
            pop() // the val from luaL_tolstring
            return result
        } else {
            return nil
        }
    }

    func tostring(_ index: CInt, encoding: String.Encoding, convert: Bool = false) -> String? {
        return tostring(index, encoding: .stringEncoding(encoding), convert: convert)
    }

    func tointeger(_ index: CInt) -> lua_Integer? {
        let L = self
        var isnum: CInt = 0
        let ret = lua_tointegerx(L, index, &isnum)
        if isnum == 0 {
            return nil
        } else {
            return ret
        }
    }

    func toint(_ index: CInt) -> Int? {
        if let int = tointeger(index) {
            return Int(exactly: int)
        } else {
            return nil
        }
    }

    func tonumber(_ index: CInt) -> Double? {
        let L = self
        var isnum: CInt = 0
        let ret = lua_tonumberx(L, index, &isnum)
        if isnum == 0 {
            return nil
        } else {
            return ret
        }
    }

    func toboolean(_ index: CInt) -> Bool {
        let b = lua_toboolean(self, index)
        return b != 0
    }

    func tostringarray(_ index: CInt, encoding: ExtendedStringEncoding? = nil, convert: Bool = false) -> [String]? {
        guard type(index) == .table else {
            return nil
        }
        var result: [String] = []
        for _ in ipairs(index) {
            if let val = tostring(-1, encoding: encoding, convert: convert) {
                result.append(val)
            } else {
                break
            }
        }
        return result
    }

    func tostringarray(_ index: CInt, encoding: String.Encoding, convert: Bool = false) -> [String]? {
        return tostringarray(index, encoding: .stringEncoding(encoding), convert: convert)
    }

    func getfield<T>(_ index: CInt, key: String, _ accessor: (CInt) -> T?) -> T? {
        let absidx = absindex(index)
        let t = self.type(absidx)
        if t != .table && t != .userdata {
            return nil // Prevent lua_gettable erroring
        }
        push(key, encoding: .ascii)
        let _ = lua_gettable(self, absidx)
        let result = accessor(-1)
        pop()
        return result
    }

    func setfuncs(_ fns: [(String, lua_CFunction)], nup: CInt = 0) {
        // It's easier to just do what luaL_setfuncs does rather than massage
        // fns in to a format that would work with it
        for (name, fn) in fns {
            for _ in 0 ..< nup {
                // copy upvalues to the top
                lua_pushvalue(self, -nup)
            }
            lua_pushcclosure(self, fn, nup)
            lua_setfield(self, -(nup + 2), name)
        }
        pop(nup)
    }

    // Convenience dict fns (assumes key is an ascii string)

    func toint(_ index: CInt, key: String) -> Int? {
        return getfield(index, key: key, self.toint)
    }

    func tonumber(_ index: CInt, key: String) -> Double? {
        return getfield(index, key: key, self.tonumber)
    }

    func toboolean(_ index: CInt, key: String) -> Bool {
        return getfield(index, key: key, self.toboolean) ?? false
    }

    func todata(_ index: CInt, key: String) -> Data? {
        return getfield(index, key: key, self.todata)
    }

    func tostring(_ index: CInt, key: String, encoding: String.Encoding, convert: Bool = false) -> String? {
        return tostring(index, key: key, encoding: .stringEncoding(encoding), convert: convert)
    }

    func tostring(_ index: CInt, key: String, encoding: ExtendedStringEncoding? = nil, convert: Bool = false) -> String? {
        return getfield(index, key: key, { tostring($0, encoding: encoding, convert: convert) })
    }

    func tostringarray(_ index: CInt, key: String, encoding: ExtendedStringEncoding? = nil, convert: Bool = false) -> [String]? {
        return getfield(index, key: key, { tostringarray($0, encoding: encoding, convert: convert) })
    }

    func tostringarray(_ index: CInt, key: String, encoding: String.Encoding, convert: Bool = false) -> [String]? {
        return tostringarray(index, key: key, encoding: .stringEncoding(encoding), convert: convert)
    }

    /// Convert a value on the Lua stack to a Swift `Any`.
    ///
    /// If `guessType` is true, `table` and `string` values are automatically converted to
    /// `Array`/`Dictionary`/`String`/`Data` based on their contents:
    ///
    /// * `string` is converted to `String` if the bytes are valid in the default string encoding, otherwise to `Data`.
    /// * `table` is converted to `Dictionary<AnyHashable, Any>` if there are any non-integer keys in the table,
    ///   otherwise to `Array<Any>`.
    ///
    /// If `guessType` is `false`, the placeholder types `LuaStringRef` and `LuaTableRef` are used for `string` and
    /// `table` values respectively.
    ///
    /// Regardless of `guessType`, the types `LuaClosureRef` and `LuaNonHashable` may be used to represent types that
    /// do not directly correspond to a Swift type.
    ///
    /// - Parameter index: The stack index.
    /// - Parameter guessType: Whether to automatically convert `string` and `table` values based on heuristics.
    /// - Returns: An `Any` representing the given index. Will only return `nil` if `index` refers to a `nil`
    ///   Lua value, all non-nil values will be converted to _some_ sort of `Any`.
    func toany(_ index: CInt, guessType: Bool = true) -> Any? {
        guard let t = type(index) else {
            return nil
        }
        switch (t) {
        case .nilType:
            return nil
        case .boolean:
            return toboolean(index)
        case .lightuserdata:
            return lua_topointer(self, index)
        case .number:
            if let intVal = toint(index) {
                return intVal
            } else {
                return tonumber(index)
            }
        case .string:
            let ref = LuaStringRef(L: self, index: index)
            if guessType {
                return ref.guessType()
            } else {
                return ref
            }
        case .table:
            let ref = LuaTableRef(L: self, index: index)
            if guessType {
                return ref.guessType()
            } else {
                return ref
            }
        case .function:
            if let fn = lua_tocfunction(self, index) {
                return fn
            } else {
                return LuaClosureRef(L: self, index: index)
            }
        case .userdata:
            return touserdata(index)
        case .thread:
            return lua_tothread(self, index)
        }
    }

    func pushany(_ value: Any?) {
        guard let value else {
            pushnil()
            return
        }
        switch value {
        case let pushable as Pushable:
            push(pushable)
        case let str as String: // HACK for _NSCFString not being Pushable??
            push(str, encoding: .utf8)
        case let num as NSNumber: // Ditto for _NSCFNumber
            if let int = num as? Int {
                push(int)
            } else {
                // Conversion to Double cannot fail
                // Curiously the Swift compiler knows enough to know this won't fail and tells us off for using the `!`
                // in a scenario when it won't fail, but helpfully doesn't provide us with a mechanism to actually get
                // a non-optional Double. The double-parenthesis tells it we know what we're doing.
                push((num as! Double))
            }
        case let data as Data: // Presumably this is needed too for NSData...
            push(data)
        case let array as Array<Any>:
            lua_createtable(self, CInt(array.count), 0)
            for (i, val) in array.enumerated() {
                pushany(val)
                lua_rawseti(self, -2, lua_Integer(i + 1))
            }
        case let dict as Dictionary<AnyHashable, Any>:
            lua_createtable(self, 0, CInt(dict.count))
            for (k, v) in dict {
                pushany(k)
                pushany(v)
                lua_settable(self, -3)
            }
        default:
            pushuserdata(value)
        }
    }

    // iterators

    class IPairsIterator : Sequence, IteratorProtocol {
        let L: LuaState
        let index: CInt
        let top: CInt?
        let requiredType: LuaType?
        var i: lua_Integer
        init(_ L: LuaState, _ index: CInt, requiredType: LuaType?, start: lua_Integer? = nil, resetTop: Bool = true) {
            precondition(requiredType != .nilType, "Cannot iterate with a required type of LUA_TNIL")
            precondition(L.type(index) == .table, "Cannot iterate something that isn't a table!")
            self.L = L
            self.index = L.absindex(index)
            self.requiredType = requiredType
            top = resetTop ? lua_gettop(L) : nil
            if let start {
                i = start - 1
            } else {
                i = 0
            }
        }
        public func next() -> lua_Integer? {
            if let top {
                L.settop(top)
            }
            i = i + 1
            let t = lua_rawgeti(L, index, i)
            if let requiredType = self.requiredType {
                if t != requiredType.rawValue {
                    L.pop()
                    return nil
                }
            } else if t == LUA_TNIL {
                L.pop()
                return nil
            }

            return i
        }
        deinit {
            if let top {
                L.settop(top)
            }
        }
    }

    /// Return a for-iterator that iterates the array part of a table.
    ///
    /// Inside the for loop, each element will on the top of the stack and
    /// can be accessed using stack index -1.
    ///
    ///     // Assuming { 11, 22, 33 } is on the top of the stack
    ///     for i in L.ipairs(-1) {
    ///         print("Index \(i) is \(L.toint(-1)!)")
    ///     }
    ///     // Prints:
    ///     // Index 1 is 11
    ///     // Index 2 is 22
    ///     // Index 3 is 33
    ///
    /// If `requiredType` is specified, iteration is halted once any value that
    /// isn't of type `requiredType` is encountered. Eg for:
    ///
    ///     for i in L.ipairs(-1, requiredType: .number) {
    ///         print(i, L.tonumber(-1)!)
    ///     }
    ///
    /// when the table at the top of the stack was `{ 11, 22, "whoops", 44 }`
    /// the iteration would stop after `22`.
    ///
    /// - Parameter index:Stack index of the table to iterate.
    /// - Parameter requiredType: An optional type which the table members must
    ///   be in order for the iteration to proceed.
    /// - Parameter start: If set, start iteration at this index rather than the
    ///   beginning of the array.
    /// - Parameter resetTop: By default, the stack top is reset on exit and 
    ///   each time through the iterator to what it was at the point of calling
    ///   `ipairs`. Occasionally (such as when using `luaL_Buffer`) this is not
    ///   desirable and can be disabled by setting `resetTop` to false.
    /// - Precondition: `requiredType` must not be `.nilType`
    /// - Precondition: `index` must refer to a table value.
    func ipairs(_ index: CInt, requiredType: LuaType? = nil, start: lua_Integer? = nil, resetTop: Bool = true) -> IPairsIterator {
        return IPairsIterator(self, index, requiredType: requiredType, start: start, resetTop: resetTop)
    }

    class PairsIterator : Sequence, IteratorProtocol {
        let L: LuaState
        let index: CInt
        let top: CInt
        init(_ L: LuaState, _ index: CInt) {
            self.L = L
            self.index = L.absindex(index)
            top = lua_gettop(L)
            lua_pushnil(L) // initial k
        }
        public func next() -> (CInt, CInt)? {
            L.settop(top + 1) // Pop everything except k
            let t = lua_next(L, index)
            if t == 0 {
                // No more items
                return nil
            }
            return (top + 1, top + 2) // k and v indexes
        }
        deinit {
            L.settop(top)
        }
    }

    /// Return a for-iterator that iterates all the members of a table.
    ///
    /// The values in the table are iterated in an unspecified order. Each time
    /// through the for loop, the iterator returns the indexes of the key and
    /// value which are pushed onto the stack. The stack is reset each time
    /// through the loop, and on exit.
    ///
    ///     // Assuming top of stack is a table { a = 1, b = 2, c = 3 }
    ///     for (k, v) in L.pairs(-1) {
    ///         print(L.tostring(k, encoding: .utf8)!, L.toint(v)!)
    ///     }
    ///     // ...might output the following:
    ///     // b 2
    ///     // c 3
    ///     // a 1
    ///
    /// - Precondition: `index` must refer to a table value.
    func pairs(_ index: CInt) -> PairsIterator {
        return PairsIterator(self, index)
    }

    func push(_ string: String, encoding: String.Encoding) {
        push(string, encoding: .stringEncoding(encoding))
    }

    func push(_ string: String, encoding: ExtendedStringEncoding) {
        guard let data = string.data(using: encoding) else {
            assertionFailure("Cannot represent string in the given encoding?!")
            pushnil()
            return
        }
        push(data)
    }

    func pushnil() {
        lua_pushnil(self)
    }

    func push<T>(_ value: T?) where T: Pushable {
        if let value = value {
            value.push(state: self)
        } else {
            self.pushnil()
        }
    }

    func push(_ fn: lua_CFunction) {
        lua_pushcfunction(self, fn)
    }

    func pop(_ nitems: CInt = 1) {
        lua_pop(self, nitems)
    }

    func gettop() -> CInt {
        return lua_gettop(self)
    }

    func settop(_ top: CInt) {
        lua_settop(self, top)
    }

    func setfield<S, T>(_ name: S, _ value: T) where S: StringProtocol & Pushable, T: Pushable {
        self.push(name)
        self.push(value)
        lua_settable(self, -3)
    }

    @discardableResult
    func getglobal(_ name: UnsafePointer<CChar>) -> LuaType {
        return LuaType(rawValue: lua_getglobal(self, name))!
    }

    /// Pushes the globals table (`_G`) onto the stack.
    func pushGlobals() {
        lua_rawgeti(self, LUA_REGISTRYINDEX, lua_Integer(LUA_RIDX_GLOBALS))
    }

    func requiref(name: UnsafePointer<CChar>!, function: lua_CFunction, global: Bool = true) {
        luaL_requiref(self, name, function, global ? 1 : 0)
        pop()
    }

    /// Make a protected call to a Lua function.
    ///
    /// The function and any arguments must already be pushed to the stack,
    /// and are popped from the stack by this call. Unless the function errors,
    /// `nret` result values are then pushed to the stack.
    ///
    /// - Parameter nargs: The number of arguments to pass to the function.
    /// - Parameter nret: The number of expected results. Can be `LUA_MULTRET`
    ///   to keep all returned values.
    /// - Parameter traceback: If true, any errors thrown will include a
    ///   full stack trace.
    /// - Throws: `LuaCallError` if a Lua error is raised during the execution
    ///   of the function.
    /// - Precondition: The top of the stack must contain a function and `nargs`
    ///   arguments.
    func pcall(nargs: CInt, nret: CInt, traceback: Bool = true) throws {
        let index: CInt
        if traceback {
            index = gettop() - nargs
            lua_pushcfunction(self, tracebackFn)
            lua_insert(self, index) // Move traceback before nargs and fn
        } else {
            index = 0
        }
        let err = lua_pcall(self, nargs, nret, index)
        if traceback {
            // Keep the stack balanced
            lua_remove(self, index)
        }
        if err != LUA_OK {
            let errStr = tostring(-1, convert: true)!
            pop()
            // print(errStr)
            throw LuaCallError(errStr)
        }
    }

    /// Convenience zero-result wrapper around `pcall(nargs:nret:traceback)`
    ///
    /// Make a protected call to a Lua function that must already be pushed
    /// onto the stack. Each of `arguments` is pushed using `pushany()`. The
    /// function is popped from the stack and any results are discarded.
    ///
    /// - Parameter arguments: Arguments to pass to the Lua function.
    /// - Parameter traceback: If true, any errors thrown will include a
    ///   full stack trace.
    /// - throws: `LuaCallError` if a Lua error is raised during the execution
    ///   of the function.
    /// - Precondition: The value at the top of the stack must refer to a Lua
    ///   function.
    func pcall(arguments: Any..., traceback: Bool = true) throws {
        for arg in arguments {
            pushany(arg)
        }
        try pcall(nargs: CInt(arguments.count), nret: 0, traceback: traceback)
    }

    /// Convenience one-result wrapper around `pcall(nargs:nret:traceback)`
    ///
    /// Make a protected call to a Lua function that must already be pushed
    /// onto the stack. Each of `arguments` is pushed using `pushany()`. The
    /// function is popped from the stack. All results are popped from the stack
    /// and the first one is converted to `T` using `tovalue<T>`. `nil` is
    /// returned if the result could not be converted to `T`.
    ///
    /// - Parameter arguments: Arguments to pass to the Lua function.
    /// - Parameter traceback: If true, any errors thrown will include a
    ///   full stack trace.
    /// - Result: The first result of the function, converted if possible to a
    ///   `T`.
    /// - throws: `LuaCallError` if a Lua error is raised during the execution
    ///   of the function.
    /// - Precondition: The value at the top of the stack must refer to a Lua
    ///   function.
    func pcall<T>(arguments: Any..., traceback: Bool = true) throws -> T? {
        for arg in arguments {
            pushany(arg)
        }
        try pcall(nargs: CInt(arguments.count), nret: 1, traceback: traceback)
        let result: T? = tovalue(-1)
        pop(1)
        return result
    }

    /// Attempt to convert the value at the given stack index to type `T`.
    ///
    /// The types of value that are convertible are:
    /// * `number` converts to `Int` if representable, otherwise `Double`
    /// * `boolean` converts to `Bool`
    /// * `thread` converts to `LuaState`
    /// * `string` converts to `String` or `Data` depending on which `T` is
    /// * `table` converts to either an `Array` or a `Dictionary` depending on `T`. The table contents are recursively
    ///   converted to match the type of `T`.
    /// * `userdata` any conversion that `as?` can perform on an `Any` referring to that type.
    func tovalue<T>(_ index: CInt) -> T? {
        let value = toany(index, guessType: false)
        if let directCast = value as? T {
            return directCast
        } else if let ref = value as? LuaStringRef {
            if T.self == String.self {
                return ref.toString() as? T
            } else /*if T.self == Data.self*/ {
                return ref.toData() as? T
            }
        } else if let ref = value as? LuaTableRef {
            return ref.resolve()
        }
        return nil
    }

    private func getMetatableName(for type: Any.Type) -> String {
        let prefix = "SwiftType_" + String(describing: type)
        let state = getState()
        if state.metatableDict[prefix] == nil {
            state.metatableDict[prefix] = []
        }
        var index = state.metatableDict[prefix]!.firstIndex(where: { $0 == type })
        if index == nil {
            state.metatableDict[prefix]!.append(type)
            index = state.metatableDict[prefix]!.count - 1
        }
        return index! == 0 ? prefix : "\(prefix)[\(index!)]"
    }

    private func doRegisterMetatable(typeName: String, functions: [String: lua_CFunction]) {
        if luaL_newmetatable(self, typeName) == 0 {
            fatalError("Metatable for type \(typeName) is already registered!")
        }
        assert(functions["__gc"] == nil, "__gc function for Swift userdata types is registered automatically")

        for (name, fn) in functions {
            lua_pushcfunction(self, fn)
            lua_setfield(self, -2, name)
        }

        if functions["__index"] == nil {
            lua_pushvalue(self, -1)
            lua_setfield(self, -2, "__index")
        }

        lua_pushcfunction(self, gcUserdata)
        lua_setfield(self, -2, "__gc")
    }

    private static let DefaultMetatableName = "SwiftType_Any"

    /// Register a metatable for values of type `T` when they are pushed using
    /// `pushuserdata()` or `pushany()`. Note, attempting to register a
    /// metatable for types that are bridged to Lua types (such as `Integer,`
    /// or `String`), will not work with values pushed with `pushany()` - if
    /// you really need to do that, they must always be pushed with
    /// `pushuserdata()` (at which point they cannot be used as normal Lua
    /// numbers/strings/etc).
    ///
    /// For example, to make a type `Foo` callable:
    ///
    ///     L.registerMetatable(for: Foo.self, functions: [
    ///         "__call": : { L in
    ///            print("TODO call support")
    ///            return 0
    ///        }
    ///     ])
    ///
    /// - Parameter for: Type to register.
    /// - Parameter functions: Map of functions.
    func registerMetatable<T>(for type: T.Type, functions: [String: lua_CFunction]) {
        doRegisterMetatable(typeName: getMetatableName(for: type), functions: functions)
        pop() // metatable
    }

    /// Register a metatable to be used for all values which have not had an
    /// explicit call to `registerMetatable`.
    ///
    /// - Parameter functions: map of functions
    func registerDefaultMetatable(functions: [String: lua_CFunction]) {
        doRegisterMetatable(typeName: Self.DefaultMetatableName, functions: functions)
        pop()
    }

    /// Push any value representable using `Any` onto the stack as a `userdata`.
    ///
    /// From a lifetime perspective, this function behaves as if `val` were
    /// assigned to another variable of type `Any`, and when the Lua userdata is
    /// garbage collected, this variable goes out of scope.
    ///
    /// - Parameter val: The value to push onto the Lua stack.
    /// - Note: This function always pushes a `userdata` - if `val` represents
    ///   any other type (for example, an integer) it will not be converted to
    ///   that type in Lua. Use `pushany()` instead to automatically convert
    ///   types to their Lua native representation where possible.
    func pushuserdata<T>(_ val: T) {
        let anyval = val as Any
        let tname = getMetatableName(for: Swift.type(of: anyval))
        pushuserdata(any: anyval, metatableName: tname)
    }

    private func pushuserdata(any val: Any, metatableName: String) {
        let udata = lua_newuserdatauv(self, MemoryLayout<Any>.size, 0)!
        let udataPtr = udata.bindMemory(to: Any.self, capacity: 1)
        udataPtr.initialize(to: val)

        if luaL_getmetatable(self, metatableName) == LUA_TNIL {
            pop()
            if luaL_getmetatable(self, Self.DefaultMetatableName) == LUA_TTABLE {
                // The stack is now right for the lua_setmetatable call below
            } else {
                pop()
                print("Implicitly registering empty metatable for type \(metatableName)")
                doRegisterMetatable(typeName: metatableName, functions: [:])
            }
        }
        lua_setmetatable(self, -2) // pops metatable
    }

    func touserdata<T>(_ index: CInt) -> T? {
        // We don't need to check the metatable name with eg luaL_testudata because we store everything as Any
        // so the final as? check takes care of that
        guard let rawptr = lua_touserdata(self, index) else {
            return nil
        }
        let typedPtr = rawptr.bindMemory(to: Any.self, capacity: 1)
        return typedPtr.pointee as? T
    }

    /// Call `block` wrapped in a `do { ... } catch {}` and convert any Swift
    /// errors into a `lua_error()` call.
    ///
    /// - Returns: The result of `block` if there was no error. On error,
    ///   converts the error to a string then calls `lua_error()` (and therefore
    ///   does not return).
    func convertThrowToError(_ block: () throws -> CInt) -> CInt {
        var nret: CInt = 0
        var errored = false
        do {
            nret = try block()
        } catch let error as LuaCallError {
            errored = true
            push(error.error)
        } catch {
            errored = true
            push("Swift error: \(error.localizedDescription)")
        }
        if errored {
            // Be careful not to leave a String (or anything else) in the stack frame here, because it won't get cleaned up,
            // hence why we push the string in the catch block above.
            return lua_error(self)
        } else {
            return nret
        }
    }
}