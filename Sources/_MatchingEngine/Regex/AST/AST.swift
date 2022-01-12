/// A regex abstract syntax tree
public indirect enum AST:
  Hashable/*, _ASTPrintable ASTValue, ASTAction*/
{
  /// ... | ... | ...
  case alternation(Alternation)

  /// ... ...
  case concatenation(Concatenation)

  /// (...)
  case group(Group)

  case quantification(Quantification)

  /// \Q...\E
  case quote(Quote)

  /// Comments, non-semantic whitespace, etc
  case trivia(Trivia)

  case atom(Atom)

  case customCharacterClass(CustomCharacterClass)

  case empty(Empty)

  // FIXME: Move off the regex literal AST
  case groupTransform(
    Group, transform: CaptureTransform)
}

// TODO: Do we want something that holds the AST and stored global options?

extension AST {
  // :-(
  //
  // Existential-based programming is highly prone to silent
  // errors, but it does enable us to avoid having to switch
  // over `self` _everywhere_ we want to do anything.
  var _associatedValue: _ASTNode {
    switch self {
    case let .alternation(v):          return v
    case let .concatenation(v):        return v
    case let .group(v):                return v
    case let .quantification(v):       return v
    case let .quote(v):                return v
    case let .trivia(v):               return v
    case let .atom(v):                 return v
    case let .customCharacterClass(v): return v
    case let .empty(v):                return v

    case let .groupTransform(g, _):
      return g // FIXME: get this out of here
    }
  }

  func `as`<T: _ASTNode>(_ t: T.Type = T.self) -> T? {
    _associatedValue as? T
  }

  /// If this node is a parent node, access its children
  public var children: [AST]? {
    return (_associatedValue as? _ASTParent)?.children
  }

  public var location: SourceLocation {
    _associatedValue.location
  }

  /// Whether this node is "trivia" or non-semantic, like comments
  public var isTrivia: Bool {
    switch self {
    case .trivia: return true
    default: return false
    }
  }

  /// Whether this node has nested somewhere inside it a capture
  public var hasCapture: Bool {
    if case let .group(g) = self, g.kind.value.isCapturing {
      return true
    } else if case let .groupTransform(g, _) = self, g.kind.value.isCapturing {
      return true
    }

    return self.children?.any(\.hasCapture) ?? false
  }
}

// MARK: - AST types

extension AST {

  public struct Alternation: Hashable, _ASTNode {
    public let children: [AST]
    public let pipes: [SourceLocation]

    public init(_ mems: [AST], pipes: [SourceLocation]) {
      // An alternation must have at least two branches (though the branches
      // may be empty AST nodes), and n - 1 pipes.
      precondition(mems.count >= 2)
      precondition(pipes.count == mems.count - 1)

      self.children = mems
      self.pipes = pipes
    }

    public var location: SourceLocation {
      .init(children.first!.location.start ..< children.last!.location.end)
    }
  }

  public struct Concatenation: Hashable, _ASTNode {
    public let children: [AST]
    public let location: SourceLocation

    public init(_ mems: [AST], _ location: SourceLocation) {
      self.children = mems
      self.location = location
    }
  }

  public struct Quote: Hashable, _ASTNode {
    public let literal: String
    public let location: SourceLocation

    public init(_ s: String, _ location: SourceLocation) {
      self.literal = s
      self.location = location
    }
  }

  public struct Trivia: Hashable, _ASTNode {
    public let contents: String
    public let location: SourceLocation

    public init(_ s: String, _ location: SourceLocation) {
      self.contents = s
      self.location = location
    }

    init(_ v: Located<String>) {
      self.contents = v.value
      self.location = v.location
    }
  }

  public struct Empty: Hashable, _ASTNode {
    public let location: SourceLocation

    public init(_ location: SourceLocation) {
      self.location = location
    }
  }
}

// FIXME: Get this out of here
public struct CaptureTransform: Equatable, Hashable, CustomStringConvertible {
  public let closure: (Substring) -> Any

  public init(_ closure: @escaping (Substring) -> Any) {
    self.closure = closure
  }

  public func callAsFunction(_ input: Substring) -> Any {
    closure(input)
  }

  public static func == (lhs: CaptureTransform, rhs: CaptureTransform) -> Bool {
    unsafeBitCast(lhs.closure, to: (Int, Int).self) ==
      unsafeBitCast(rhs.closure, to: (Int, Int).self)
  }

  public func hash(into hasher: inout Hasher) {
    let (fn, ctx) = unsafeBitCast(closure, to: (Int, Int).self)
    hasher.combine(fn)
    hasher.combine(ctx)
  }

  public var description: String {
    "<transform>"
  }
}

