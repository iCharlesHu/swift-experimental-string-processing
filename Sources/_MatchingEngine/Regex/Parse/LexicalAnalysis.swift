//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2021-2022 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
//
//===----------------------------------------------------------------------===//

/*

Lexical analysis aids parsing by handling local ("lexical")
concerns upon request.

API convention:

- lexFoo will try to consume a foo and return it if successful, throws errors
- expectFoo will consume a foo, throwing errors, and throw an error if it can't
- eat() and tryEat() is still used by the parser as a character-by-character interface
*/

extension Source {
  // MARK: - recordLoc

  /// Record source loc before processing and return
  /// or throw the value/error with source locations.
  fileprivate mutating func recordLoc<T>(
    _ f: (inout Self) throws -> T
  ) rethrows -> Located<T> {
    let start = currentPosition
    do {
      let result = try f(&self)
      return Located(result, Location(start..<currentPosition))
    } catch let e as LocatedError<ParseError> {
      throw e
    } catch let e as ParseError {
      throw LocatedError(e, Location(start..<currentPosition))
    } catch {
      fatalError("FIXME: Let's not keep the boxed existential...")
    }
  }

  /// Record source loc before processing and return
  /// or throw the value/error with source locations.
  fileprivate mutating func recordLoc<T>(
    _ f: (inout Self) throws -> T?
  ) rethrows -> Located<T>? {
    let start = currentPosition
    do {
      guard let result = try f(&self) else { return nil }
      return Located(result, start..<currentPosition)
    } catch let e as Source.LocatedError<ParseError> {
      throw e
    } catch let e as ParseError {
      throw LocatedError(e, start..<currentPosition)
    } catch {
      fatalError("FIXME: Let's not keep the boxed existential...")
    }
  }

  /// Record source loc before processing and return
  /// or throw the value/error with source locations.
  fileprivate mutating func recordLoc(
    _ f: (inout Self) throws -> ()
  ) rethrows {
    let start = currentPosition
    do {
      try f(&self)
    } catch let e as Source.LocatedError<ParseError> {
      throw e
    } catch let e as ParseError {
      throw LocatedError(e, start..<currentPosition)
    } catch {
      fatalError("FIXME: Let's not keep the boxed existential...")
    }
  }
}

// MARK: - Consumption routines
extension Source {
  typealias Quant = AST.Quantification

  /// Throws an expected character error if not matched
  mutating func expect(_ c: Character) throws {
    _ = try recordLoc { src in
      guard src.tryEat(c) else {
        throw ParseError.expected(String(c))
      }
    }
  }

  /// Throws an expected character error if not matched
  mutating func expect<C: Collection>(
    sequence c: C
  ) throws where C.Element == Character {
    _ = try recordLoc { src in
      guard src.tryEat(sequence: c) else {
        throw ParseError.expected(String(c))
      }
    }
  }

  /// Throws an unexpected end of input error if not matched
  ///
  /// Note: much of the time, but not always, we can vend a more specific error.
  mutating func expectNonEmpty() throws {
    _ = try recordLoc { src in
      if src.isEmpty { throw ParseError.unexpectedEndOfInput }
    }
  }

  mutating func tryEatNonEmpty<C: Collection>(sequence c: C) throws -> Bool
    where C.Element == Char
  {
    _ = try recordLoc { src in
      guard !src.isEmpty else { throw ParseError.expected(String(c)) }
    }
    return tryEat(sequence: c)
  }

  mutating func tryEatNonEmpty(_ c: Char) throws -> Bool {
    try tryEatNonEmpty(sequence: String(c))
  }

  /// Attempt to make a series of lexing steps in `body`, returning `nil` if
  /// unsuccesful, which will revert the source back to its previous state. If
  /// an error is thrown, the source will not be reverted.
  mutating func tryEating<T>(
    _ body: (inout Source) throws -> T?
  ) rethrows -> T? {
    // We don't revert the source if an error is thrown, as it's useful to
    // maintain the source location in that case.
    let current = self
    guard let result = try body(&self) else {
      self = current
      return nil
    }
    return result
  }

  /// Throws an expected ASCII character error if not matched
  mutating func expectASCII() throws -> Located<Character> {
    try recordLoc { src in
      guard let c = src.peek() else {
        throw ParseError.unexpectedEndOfInput
      }
      guard c.isASCII else {
        throw ParseError.expectedASCII(c)
      }
      src.eat(asserting: c)
      return c
    }
  }
}

enum RadixKind {
  case octal, decimal, hex

  var characterFilter: (Character) -> Bool {
    switch self {
    case .octal:   return \.isOctalDigit
    case .decimal: return \.isNumber
    case .hex:     return \.isHexDigit
    }
  }
  var radix: Int {
    switch self {
    case .octal:   return 8
    case .decimal: return 10
    case .hex:     return 16
    }
  }
}

extension Source {
  /// Validate a string of digits as a particular radix, and return the number,
  /// or throw an error if the string is malformed or would overflow the number
  /// type.
  private static func validateNumber<Num: FixedWidthInteger>(
    _ str: String, _: Num.Type, _ kind: RadixKind
  ) throws -> Num {
    guard !str.isEmpty && str.all(kind.characterFilter) else {
      throw ParseError.expectedNumber(str, kind: kind)
    }
    guard let i = Num(str, radix: kind.radix) else {
      throw ParseError.numberOverflow(str)
    }
    return i
  }

  /// Validate a string of digits as a unicode scalar of a particular radix, and
  /// return the scalar value, or throw an error if the string is malformed or
  /// would overflow the scalar.
  private static func validateUnicodeScalar(
    _ str: String, _ kind: RadixKind
  ) throws -> Unicode.Scalar {
    let num = try validateNumber(str, UInt32.self, kind)
    guard let scalar = Unicode.Scalar(num) else {
      throw ParseError.misc("Invalid scalar value U+\(num.hexStr)")
    }
    return scalar
  }

  /// Try to eat a number of a particular type and radix off the front.
  ///
  /// Returns: `nil` if there's no number, otherwise the number
  ///
  /// Throws on overflow
  ///
  private mutating func lexNumber<Num: FixedWidthInteger>(
    _ ty: Num.Type, _ kind: RadixKind
  ) throws -> Located<Num>? {
    try recordLoc { src in
      guard let str = src.tryEatPrefix(kind.characterFilter)?.string else {
        return nil
      }
      guard let i = Num(str, radix: kind.radix) else {
        throw ParseError.numberOverflow(str)
      }
      return i
    }
  }

  /// Try to eat a number off the front.
  ///
  /// Returns: `nil` if there's no number, otherwise the number
  ///
  /// Throws on overflow
  ///
  mutating func lexNumber() throws -> Located<Int>? {
    try lexNumber(Int.self, .decimal)
  }

  mutating func expectNumber() throws -> Located<Int> {
    guard let num = try lexNumber() else {
      throw ParseError.expectedNumber("", kind: .decimal)
    }
    return num
  }

  /// Eat a scalar value from hexadecimal notation off the front
  private mutating func expectUnicodeScalar(
    numDigits: Int
  ) throws -> Located<Unicode.Scalar> {
    try recordLoc { src in
      let str = src.eat(upToCount: numDigits).string
      guard str.count == numDigits else {
        throw ParseError.expectedNumDigits(str, numDigits)
      }
      return try Source.validateUnicodeScalar(str, .hex)
    }
  }

  /// Eat a scalar off the front, starting from after the
  /// backslash and base character (e.g. `\u` or `\x`).
  ///
  ///     UniScalar -> 'u{' HexDigit{1...} '}'
  ///                | 'u'  HexDigit{4}
  ///                | 'x{' HexDigit{1...} '}'
  ///                | 'x'  HexDigit{0...2}
  ///                | 'U'  HexDigit{8}
  ///                | 'o{' OctalDigit{1...} '}'
  ///                | OctalDigit{1...3}
  ///
  mutating func expectUnicodeScalar(
    escapedCharacter base: Character
  ) throws -> Located<Unicode.Scalar> {
    try recordLoc { src in
      // TODO: PCRE offers a different behavior if PCRE2_ALT_BSUX is set.
      switch base {
      // Hex numbers.
      case "u" where src.tryEat("{"), "x" where src.tryEat("{"):
        let str = try src.lexUntil(eating: "}").value
        return try Source.validateUnicodeScalar(str, .hex)

      case "x":
        // \x expects *up to* 2 digits.
        guard let digits = src.tryEatPrefix(maxLength: 2, \.isHexDigit) else {
          // In PCRE, \x without any valid hex digits is \u{0}.
          // TODO: This doesn't appear to be followed by ICU or Oniguruma, so
          // could be changed to throw an error if we had a parsing mode for
          // them.
          return Unicode.Scalar(0)
        }
        return try Source.validateUnicodeScalar(digits.string, .hex)

      case "u":
        return try src.expectUnicodeScalar(numDigits: 4).value
      case "U":
        return try src.expectUnicodeScalar(numDigits: 8).value

      // Octal numbers.
      case "o" where src.tryEat("{"):
        let str = try src.lexUntil(eating: "}").value
        return try Source.validateUnicodeScalar(str, .octal)

      case let c where c.isOctalDigit:
        // We can read *up to* 2 more octal digits per PCRE.
        // FIXME: ICU can read up to 3 octal digits if the leading digit is 0,
        // we should have a parser mode to switch.
        let nextDigits = src.tryEatPrefix(maxLength: 2, \.isOctalDigit)
        let str = String(c) + (nextDigits?.string ?? "")
        return try Source.validateUnicodeScalar(str, .octal)

      default:
        fatalError("Unexpected scalar start")
      }
    }
  }

  /// Try to consume a quantifier
  ///
  ///     Quantifier -> ('*' | '+' | '?' | '{' Range '}') QuantKind?
  ///     QuantKind  -> '?' | '+'
  ///
  mutating func lexQuantifier() throws -> (
    Located<Quant.Amount>, Located<Quant.Kind>
  )? {
    let amt: Located<Quant.Amount>? = try recordLoc { src in
      if src.tryEat("*") { return .zeroOrMore }
      if src.tryEat("+") { return .oneOrMore }
      if src.tryEat("?") { return .zeroOrOne }

      return try src.tryEating { src in
        guard src.tryEat("{"), let range = try src.lexRange(), src.tryEat("}")
        else { return nil }
        return range.value
      }
    }
    guard let amt = amt else { return nil }

    let kind: Located<Quant.Kind> = recordLoc { src in
      if src.tryEat("?") { return .reluctant  }
      if src.tryEat("+") { return .possessive }
      return .eager
    }

    return (amt, kind)
  }

  /// Try to consume a range, returning `nil` if unsuccessful.
  ///
  ///     Range       -> ',' <Int> | <Int> ',' <Int>? | <Int>
  ///                  | ExpRange
  ///     ExpRange    -> '..<' <Int> | '...' <Int>
  ///                  | <Int> '..<' <Int> | <Int> '...' <Int>?
  mutating func lexRange() throws -> Located<Quant.Amount>? {
    try recordLoc { src in
      try src.tryEating { src in
        let lowerOpt = try src.lexNumber()

        // ',' or '...' or '..<' or nothing
        // TODO: We ought to try and consume whitespace here and emit a
        // diagnostic for the user warning them that it would cause the range to
        // be treated as literal.
        let closedRange: Bool?
        if src.tryEat(",") {
          closedRange = true
        } else if src.experimentalRanges && src.tryEat(".") {
          try src.expect(".")
          if src.tryEat(".") {
            closedRange = true
          } else {
            try src.expect("<")
            closedRange = false
          }
        } else {
          closedRange = nil
        }

        let upperOpt = try src.lexNumber()?.map { upper in
          // If we have an open range, the upper bound should be adjusted down.
          closedRange == true ? upper : upper - 1
        }

        switch (lowerOpt, closedRange, upperOpt) {
        case let (l?, nil, nil):
          return .exactly(l)
        case let (l?, true, nil):
          return .nOrMore(l)
        case let (nil, _?, u?):
          return .upToN(u)
        case let (l?, _?, u?):
          return .range(l, u)

        case (nil, nil, _?):
          fatalError("Didn't lex lower bound, but lexed upper bound?")
        default:
          return nil
        }
      }
    }
  }

  private mutating func lexUntil(
    _ predicate: (inout Source) throws -> Bool
  ) rethrows -> Located<String> {
    try recordLoc { src in
      var result = ""
      while try !predicate(&src) {
        result.append(src.eat())
      }
      return result
    }
  }

  private mutating func lexUntil(eating end: String) throws -> Located<String> {
    try lexUntil { try $0.tryEatNonEmpty(sequence: end) }
  }

  private mutating func lexUntil(
    eating end: Character
  ) throws -> Located<String> {
    try lexUntil(eating: String(end))
  }

  /// Expect a linear run of non-nested non-empty content ending with a given
  /// delimiter. If `ignoreEscaped` is true, escaped characters will not be
  /// considered for the ending delimiter.
  private mutating func expectQuoted(
    endingWith end: String, ignoreEscaped: Bool = false
  ) throws -> Located<String> {
    try recordLoc { src in
      let result = try src.lexUntil { src in
        if try src.tryEatNonEmpty(sequence: end) {
          return true
        }
        // Ignore escapes if we're allowed to. lexUntil will consume the next
        // character.
        if ignoreEscaped, src.tryEat("\\") {
          try src.expectNonEmpty()
        }
        return false
      }.value
      guard !result.isEmpty else {
        throw ParseError.expectedNonEmptyContents
      }
      return result
    }
  }

  /// Try to consume quoted content
  ///
  ///     Quote -> '\Q' (!'\E' .)* '\E'
  ///
  /// With `SyntaxOptions.experimentalQuotes`, also accepts
  ///
  ///     ExpQuote -> '"' ('\"' | [^"])* '"'
  ///
  /// Future: Experimental quotes are full fledged Swift string literals
  ///
  /// TODO: Need to support some escapes
  ///
  mutating func lexQuote() throws -> Located<String>? {
    try recordLoc { src in
      if src.tryEat(sequence: #"\Q"#) {
        return try src.expectQuoted(endingWith: #"\E"#).value
      }
      if src.experimentalQuotes, src.tryEat("\"") {
        return try src.expectQuoted(endingWith: "\"", ignoreEscaped: true).value
      }
      return nil
    }
  }

  /// Try to consume a comment
  ///
  ///     Comment -> '(?#' [^')']* ')'
  ///
  /// With `SyntaxOptions.experimentalComments`
  ///
  ///     ExpComment -> '/*' (!'*/' .)* '*/'
  ///
  /// TODO: Swift-style nested comments, line-ending comments, etc
  ///
  mutating func lexComment() throws -> AST.Trivia? {
    let trivia: Located<String>? = try recordLoc { src in
      if src.tryEat(sequence: "(?#") {
        return try src.expectQuoted(endingWith: ")").value
      }
      if src.experimentalComments, src.tryEat(sequence: "/*") {
        return try src.expectQuoted(endingWith: "*/").value
      }
      return nil
    }
    guard let trivia = trivia else { return nil }
    return AST.Trivia(trivia)
  }

  /// Try to consume non-semantic whitespace as trivia
  ///
  /// Does nothing unless `SyntaxOptions.nonSemanticWhitespace` is set
  mutating func lexNonSemanticWhitespace() throws -> AST.Trivia? {
    guard syntax.ignoreWhitespace else { return nil }
    let trivia: Located<String>? = recordLoc { src in
      src.tryEatPrefix { $0 == " " }?.string
    }
    guard let trivia = trivia else { return nil }
    return AST.Trivia(trivia)
  }

  /// Try to lex a matching option.
  ///
  ///     MatchingOption -> 'i' | 'J' | 'm' | 'n' | 's' | 'U' | 'x' | 'xx' | 'w'
  ///                     | 'D' | 'P' | 'S' | 'W' | 'y{' ('g' | 'w') '}'
  ///
  mutating func lexMatchingOption() throws -> AST.MatchingOption? {
    typealias OptKind = AST.MatchingOption.Kind

    let locOpt = try recordLoc { src -> OptKind? in
      func advanceAndReturn(_ o: OptKind) -> OptKind {
        src.advance()
        return o
      }
      guard let c = src.peek() else { return nil }
      switch c {
      // PCRE options.
      case "i": return advanceAndReturn(.caseInsensitive)
      case "J": return advanceAndReturn(.allowDuplicateGroupNames)
      case "m": return advanceAndReturn(.multiline)
      case "n": return advanceAndReturn(.noAutoCapture)
      case "s": return advanceAndReturn(.singleLine)
      case "U": return advanceAndReturn(.reluctantByDefault)
      case "x":
        src.advance()
        return src.tryEat("x") ? .extraExtended : .extended

      // ICU options.
      case "w": return advanceAndReturn(.unicodeWordBoundaries)

      // Oniguruma options.
      case "D": return advanceAndReturn(.asciiOnlyDigit)
      case "P": return advanceAndReturn(.asciiOnlyPOSIXProps)
      case "S": return advanceAndReturn(.asciiOnlySpace)
      case "W": return advanceAndReturn(.asciiOnlyWord)
      case "y":
        src.advance()
        try src.expect("{")
        let opt: OptKind
        if src.tryEat("w") {
          opt = .textSegmentWordMode
        } else {
          try src.expect("g")
          opt = .textSegmentGraphemeMode
        }
        try src.expect("}")
        return opt

      default:
        return nil
      }
    }
    guard let locOpt = locOpt else { return nil }
    return .init(locOpt.value, location: locOpt.location)
  }

  /// Try to lex a sequence of matching options.
  ///
  ///     MatchingOptionSeq -> '^' MatchingOption* | MatchingOption+
  ///                        | MatchingOption* '-' MatchingOption*
  ///
  mutating func lexMatchingOptionSequence(
  ) throws -> AST.MatchingOptionSequence? {
    let ateCaret = recordLoc { $0.tryEat("^") }

    // TODO: Warn on duplicate options, and options appearing in both adding
    // and removing lists?
    var adding: [AST.MatchingOption] = []
    while let opt = try lexMatchingOption() {
      adding.append(opt)
    }

    // If the sequence begun with a caret '^', options can only be added, so
    // we're done.
    if ateCaret.value {
      if peek() == "-" {
        throw ParseError.cannotRemoveMatchingOptionsAfterCaret
      }
      return .init(caretLoc: ateCaret.location, adding: adding, minusLoc: nil,
                   removing: [])
    }

    // Try to lex options to remove.
    let ateMinus = recordLoc { $0.tryEat("-") }
    if ateMinus.value {
      var removing: [AST.MatchingOption] = []
      while let opt = try lexMatchingOption() {
        // Text segment options can only be added, they cannot be removed
        // with (?-), they should instead be set to a different mode.
        if opt.isTextSegmentMode {
          throw ParseError.cannotRemoveTextSegmentOptions
        }
        removing.append(opt)
      }
      return .init(caretLoc: nil, adding: adding, minusLoc: ateMinus.location,
                   removing: removing)
    }
    guard !adding.isEmpty else { return nil }
    return .init(caretLoc: nil, adding: adding, minusLoc: nil, removing: [])
  }

  /// Try to consume the start of a group
  ///
  ///     GroupStart -> '(?' GroupKind | '('
  ///     GroupKind  -> Named | ':' | '|' | '>' | '=' | '!' | '*' | '<=' | '<!'
  ///                 | '<*' | MatchingOptionSeq (':' | ')')
  ///     Named      -> '<' [^'>']+ '>' | 'P<' [^'>']+ '>'
  ///                 | '\'' [^'\'']+ '\''
  ///
  /// If `SyntaxOptions.experimentalGroups` is enabled, also accepts:
  ///
  ///     ExpGroupStart -> '(_:'
  ///
  /// Future: Named groups of the form `(name: ...)`
  ///
  /// Note: we exclude comments from being `Group`s, since
  /// they do not nest: they parse like quotes. They actually
  /// need to be parsed earlier than the group check, as
  /// comments, like quotes, cannot be quantified.
  ///
  mutating func lexGroupStart(
  ) throws -> Located<AST.Group.Kind>? {
    try recordLoc { src in
      try src.tryEating { src in
        guard src.tryEat("(") else { return nil }

        if src.tryEat("?") {
          if src.tryEat(":") { return .nonCapture }
          if src.tryEat("|") { return .nonCaptureReset }
          if src.tryEat(">") { return .atomicNonCapturing }
          if src.tryEat("=") { return .lookahead }
          if src.tryEat("!") { return .negativeLookahead }
          if src.tryEat("*") { return .nonAtomicLookahead }

          if src.tryEat(sequence: "<=") { return .lookbehind }
          if src.tryEat(sequence: "<!") { return .negativeLookbehind }
          if src.tryEat(sequence: "<*") { return .nonAtomicLookbehind }

          // Named
          // TODO: Group name validation, PCRE (and ICU + Oniguruma as far as I
          // can tell), enforce word characters only, with the first character
          // being a non-digit.
          if src.tryEat("<") || src.tryEat(sequence: "P<") {
            let name = try src.expectQuoted(endingWith: ">")
            return .namedCapture(name)
          }
          if src.tryEat("'") {
            let name = try src.expectQuoted(endingWith: "'")
            return .namedCapture(name)
          }

          // Check if we can lex a group-like reference. Do this before matching
          // options to avoid ambiguity with a group starting with (?-, which
          // is a subpattern if the next character is a digit, otherwise a
          // matching option specifier. In addition, we need to be careful with
          // (?P, which can also be the start of a matching option sequence.
          if src.canLexGroupLikeReference() {
            return nil
          }

          // Matching option changing group (?iJmnsUxxxDPSWy{..}-iJmnsUxxxDPSW:).
          if let seq = try src.lexMatchingOptionSequence() {
            if src.tryEat(":") {
              return .changeMatchingOptions(seq, isIsolated: false)
            }
            // If this isn't start of an explicit group, we should have an
            // implicit group that covers the remaining elements of the current
            // group.
            // TODO: This implicit scoping behavior matches Oniguruma, but PCRE
            // also does it across alternations, which will require additional
            // handling.
            guard src.tryEat(")") else {
              if let next = src.peek() {
                throw ParseError.invalidMatchingOption(next)
              }
              throw ParseError.expected(")")
            }
            return .changeMatchingOptions(seq, isIsolated: true)
          }

          guard let next = src.peek() else {
            throw ParseError.expectedGroupSpecifier
          }
          throw ParseError.unknownGroupKind("?\(next)")
        }

        // Explicitly spelled out PRCE2 syntax for some groups.
        if src.tryEat("*") {
          if src.tryEat(sequence: "atomic:") { return .atomicNonCapturing }

          if src.tryEat(sequence: "pla:") ||
              src.tryEat(sequence: "positive_lookahead:") {
            return .lookahead
          }
          if src.tryEat(sequence: "nla:") ||
              src.tryEat(sequence: "negative_lookahead:") {
            return .negativeLookahead
          }
          if src.tryEat(sequence: "plb:") ||
              src.tryEat(sequence: "positive_lookbehind:") {
            return .lookbehind
          }
          if src.tryEat(sequence: "nlb:") ||
              src.tryEat(sequence: "negative_lookbehind:") {
            return .negativeLookbehind
          }
          if src.tryEat(sequence: "napla:") ||
              src.tryEat(sequence: "non_atomic_positive_lookahead:") {
            return .nonAtomicLookahead
          }
          if src.tryEat(sequence: "naplb:") ||
              src.tryEat(sequence: "non_atomic_positive_lookbehind:") {
            return .nonAtomicLookbehind
          }
          if src.tryEat(sequence: "sr:") || src.tryEat(sequence: "script_run:") {
            return .scriptRun
          }
          if src.tryEat(sequence: "asr:") ||
              src.tryEat(sequence: "atomic_script_run:") {
            return .atomicScriptRun
          }

          throw ParseError.misc("Quantifier '*' must follow operand")
        }

        // (_:)
        if src.experimentalCaptures && src.tryEat(sequence: "_:") {
          return .nonCapture
        }
        // TODO: (name:)

        return .capture
      }
    }
  }

  mutating func lexCustomCCStart(
  ) throws -> Located<CustomCC.Start>? {
    recordLoc { src in
      // POSIX named sets are atoms.
      guard !src.starts(with: "[:") else { return nil }

      if src.tryEat("[") {
        return src.tryEat("^") ? .inverted : .normal
      }
      return nil
    }
  }

  /// Try to consume a binary operator from within a custom character class
  ///
  ///     CustomCCBinOp -> '--' | '~~' | '&&'
  ///
  mutating func lexCustomCCBinOp() throws -> Located<CustomCC.SetOp>? {
    recordLoc { src in
      // TODO: Perhaps a syntax options check (!PCRE)
      // TODO: Better AST types here
      guard let binOp = src.peekCCBinOp() else { return nil }
      try! src.expect(sequence: binOp.rawValue)
      return binOp
    }
  }

  // Check to see if we can lex a binary operator.
  func peekCCBinOp() -> CustomCC.SetOp? {
    if starts(with: "--") { return .subtraction }
    if starts(with: "~~") { return .symmetricDifference }
    if starts(with: "&&") { return .intersection }
    return nil
  }

  private mutating func lexPOSIXCharacterProperty(
  ) throws -> Located<AST.Atom.CharacterProperty>? {
    try recordLoc { src in
      guard src.tryEat(sequence: "[:") else { return nil }
      let inverted = src.tryEat("^")
      let prop = try src.lexCharacterPropertyContents(end: ":]").value
      return .init(prop, isInverted: inverted, isPOSIX: true)
    }
  }

  /// Try to consume a named character.
  ///
  ///     NamedCharacter -> '\N{' CharName '}'
  ///     CharName -> 'U+' HexDigit{1...8} | [\s\w-]+
  ///
  private mutating func lexNamedCharacter() throws -> Located<AST.Atom.Kind>? {
    try recordLoc { src in
      guard src.tryEat(sequence: "N{") else { return nil }

      // We should either have a unicode scalar.
      if src.tryEat(sequence: "U+") {
        let str = try src.lexUntil(eating: "}").value
        return .scalar(try Source.validateUnicodeScalar(str, .hex))
      }

      // Or we should have a character name.
      // TODO: Validate the types of characters that can appear in the name?
      return .namedCharacter(try src.lexUntil(eating: "}").value)
    }
  }

  private mutating func lexCharacterPropertyContents(
    end: String
  ) throws -> Located<AST.Atom.CharacterProperty.Kind> {
    try recordLoc { src in
      // We should either have:
      // - 'x=y' where 'x' is a property key, and 'y' is a value.
      // - 'y' where 'y' is a value (or a bool key with an inferred value
      //   of true), and its key is inferred.
      // TODO: We could have better recovery here if we only ate the characters
      // that property keys and values can use.
      let lhs = src.lexUntil {
        $0.isEmpty || $0.peek() == "=" || $0.starts(with: end)
      }.value
      if src.tryEat("=") {
        let rhs = try src.lexUntil(eating: end).value
        return try Source.classifyCharacterProperty(key: lhs, value: rhs)
      }
      try src.expect(sequence: end)
      return try Source.classifyCharacterPropertyValueOnly(lhs)
    }
  }

  /// Try to consume a character property.
  ///
  ///     Property -> ('p{' | 'P{') Prop ('=' Prop)? '}'
  ///     Prop -> [\s\w-]+
  ///
  private mutating func lexCharacterProperty(
  ) throws -> Located<AST.Atom.CharacterProperty>? {
    try recordLoc { src in
      // '\P{...}' is the inverted version of '\p{...}'
      guard src.starts(with: "p{") || src.starts(with: "P{") else { return nil }
      let isInverted = src.peek() == "P"
      src.advance(2)

      let prop = try src.lexCharacterPropertyContents(end: "}").value
      return .init(prop, isInverted: isInverted, isPOSIX: false)
    }
  }

  /// Try to lex an absolute or relative numbered reference.
  ///
  ///     NumberRef -> ('+' | '-')? <Decimal Number>
  ///
  private mutating func lexNumberedReference(
  ) throws -> AST.Atom.Reference? {
    let kind = try recordLoc { src -> AST.Atom.Reference.Kind? in
      // Note this logic should match canLexNumberedReference.
      if src.tryEat("+") {
        return .relative(try src.expectNumber().value)
      }
      if src.tryEat("-") {
        return .relative(try -src.expectNumber().value)
      }
      if let num = try src.lexNumber() {
        return .absolute(num.value)
      }
      return nil
    }
    guard let kind = kind else { return nil }
    return .init(kind.value, innerLoc: kind.location)
  }

  /// Checks whether a numbered reference can be lexed.
  private func canLexNumberedReference() -> Bool {
    var src = self
    _ = src.tryEat(anyOf: "+", "-")
    guard let next = src.peek() else { return false }
    return RadixKind.decimal.characterFilter(next)
  }

  /// Eat a named reference up to a given closing delimiter.
  private mutating func expectNamedReference(
    endingWith end: String
  ) throws -> AST.Atom.Reference {
    // TODO: Group name validation, see comment in lexGroupStart.
    let str = try expectQuoted(endingWith: end)
    return .init(.named(str.value), innerLoc: str.location)
  }

  /// Try to lex a numbered reference, or otherwise a named reference.
  ///
  ///     NameOrNumberRef -> NumberRef | <String>
  ///
  private mutating func expectNamedOrNumberedReference(
    endingWith ending: String
  ) throws -> AST.Atom.Reference {
    if let numbered = try lexNumberedReference() {
      try expect(sequence: ending)
      return numbered
    }
    return try expectNamedReference(endingWith: ending)
  }

  private static func getClosingDelimiter(
    for openChar: Character
  ) -> Character {
    switch openChar {
      case "<": return ">"
      case "'": return "'"
      case "{": return "}"
      default:
        fatalError("Not implemented")
    }
  }

  /// Lex an escaped reference for a backreference or subpattern.
  ///
  ///     EscapedReference -> 'g{' NameOrNumberRef '}'
  ///                       | 'g<' NameOrNumberRef '>'
  ///                       | "g'" NameOrNumberRef "'"
  ///                       | 'g' NumberRef
  ///                       | 'k<' <String> '>'
  ///                       | "k'" <String> "'"
  ///                       | 'k{' <String> '}'
  ///                       | [1-9] [0-9]+
  ///
  private mutating func lexEscapedReference(
    priorGroupCount: Int
  ) throws -> Located<AST.Atom.Kind>? {
    try recordLoc { src in
      try src.tryEating { src in
        guard let firstChar = src.peek() else { return nil }

        if src.tryEat("g") {
          // PCRE-style backreferences.
          if src.tryEat("{") {
            let ref = try src.expectNamedOrNumberedReference(endingWith: "}")
            return .backreference(ref)
          }

          // Oniguruma-style subpatterns.
          if let openChar = src.tryEat(anyOf: "<", "'") {
            let closing = String(Source.getClosingDelimiter(for: openChar))
            return .subpattern(
              try src.expectNamedOrNumberedReference(endingWith: closing))
          }

          // PCRE allows \g followed by a bare numeric reference.
          if let ref = try src.lexNumberedReference() {
            return .backreference(ref)
          }
          return nil
        }

        if src.tryEat("k") {
          // Perl/.NET-style backreferences.
          if let openChar = src.tryEat(anyOf: "<", "'", "{") {
            let closing = String(Source.getClosingDelimiter(for: openChar))
            return .backreference(
              try src.expectNamedReference(endingWith: closing))
          }
          return nil
        }

        // Lexing \n is tricky, as it's ambiguous with octal sequences. In PCRE
        // it is treated as a backreference if its first digit is not 0 (as that
        // is always octal) and one of the following holds:
        //
        // - It's 0 < n < 10 (as octal would be pointless here)
        // - Its first digit is 8 or 9 (as not valid octal)
        // - There have been as many prior groups as the reference.
        //
        // Oniguruma follows the same rules except the second one. e.g \81 and
        // \91 are instead treated as literal 81 and 91 respectively.
        // TODO: If we want a strict Oniguruma mode, we'll need to add a check
        // here.
        if firstChar != "0", let numAndLoc = try src.lexNumber() {
          let num = numAndLoc.value
          let loc = numAndLoc.location
          if num < 10 || firstChar == "8" || firstChar == "9" ||
              num <= priorGroupCount {
            return .backreference(.init(.absolute(num), innerLoc: loc))
          }
          return nil
        }
        return nil
      }
    }
  }

  /// Try to lex a reference that syntactically looks like a group.
  ///
  ///     GroupLikeReference -> '(?' GroupLikeReferenceBody ')'
  ///     GroupLikeReferenceBody -> 'P=' <String>
  ///                             | 'P>' <String>
  ///                             | '&' <String>
  ///                             | 'R'
  ///                             | NumberRef
  ///
  private mutating func lexGroupLikeReference(
  ) throws -> Located<AST.Atom.Kind>? {
    try recordLoc { src in
      try src.tryEating { src in
        guard src.tryEat(sequence: "(?") else { return nil }
        let _start = src.currentPosition

        // Note the below should be covered by canLexGroupLikeReference.

        // Python-style references.
        if src.tryEat(sequence: "P=") {
          return .backreference(try src.expectNamedReference(endingWith: ")"))
        }
        if src.tryEat(sequence: "P>") {
          return .subpattern(try src.expectNamedReference(endingWith: ")"))
        }

        // Perl-style subpatterns.
        if src.tryEat("&") {
          return .subpattern(try src.expectNamedReference(endingWith: ")"))
        }

        // Whole-pattern recursion, which is equivalent to (?0).
        if src.tryEat("R") {
          let loc = Location(_start ..< src.currentPosition)
          try src.expect(")")
          return .subpattern(.init(.recurseWholePattern, innerLoc: loc))
        }

        // Numbered subpattern reference.
        if let ref = try src.lexNumberedReference() {
          try src.expect(")")
          return .subpattern(ref)
        }
        return nil
      }
    }
  }

  /// Whether we can lex a group-like reference after the specifier '(?'.
  private func canLexGroupLikeReference() -> Bool {
    var src = self
    if src.tryEat("P") {
      return src.tryEat(anyOf: "=", ">") != nil
    }
    if src.tryEat(anyOf: "&", "R") != nil {
      return true
    }
    return src.canLexNumberedReference()
  }

  /// Consume an escaped atom, starting from after the backslash
  ///
  ///     Escaped          -> KeyboardModified | Builtin
  ///                       | UniScalar | Property | NamedCharacter
  ///                       | EscapedReference
  ///
  mutating func expectEscaped(
    isInCustomCharacterClass ccc: Bool, priorGroupCount: Int
  ) throws -> Located<AST.Atom.Kind> {
    try recordLoc { src in
      // Keyboard control/meta
      if src.tryEat("c") || src.tryEat(sequence: "C-") {
        return .keyboardControl(try src.expectASCII().value)
      }
      if src.tryEat(sequence: "M-\\C-") {
        return .keyboardMetaControl(try src.expectASCII().value)
      }
      if src.tryEat(sequence: "M-") {
        return .keyboardMeta(try src.expectASCII().value)
      }

      // Named character '\N{...}'.
      if let char = try src.lexNamedCharacter() {
        return char.value
      }

      // Character property \p{...} \P{...}.
      if let prop = try src.lexCharacterProperty() {
        return .property(prop.value)
      }

      // References using escape syntax, e.g \1, \g{1}, \k<...>, ...
      // These are not valid inside custom character classes.
      if !ccc, let ref = try src.lexEscapedReference(
        priorGroupCount: priorGroupCount
      )?.value {
        return ref
      }

      let char = src.eat()

      // Single-character builtins.
      if let builtin = AST.Atom.EscapedBuiltin(
        char, inCustomCharacterClass: ccc
      ) {
        return .escaped(builtin)
      }

      switch char {
      // Hexadecimal and octal unicode scalars. This must be done after
      // backreference lexing due to the ambiguity with \nnn.
      case let c where c.isOctalDigit: fallthrough
      case "u", "x", "U", "o":
        return try .scalar(
          src.expectUnicodeScalar(escapedCharacter: char).value)
      default:
        return .char(char)
      }
    }
  }


  /// Try to consume an Atom.
  ///
  ///     Atom             -> SpecialCharacter | POSIXSet
  ///                       | '\' Escaped | [^')' '|']
  ///     SpecialCharacter -> '.' | '^' | '$'
  ///     POSIXSet         -> '[:' name ':]'
  ///
  /// If `SyntaxOptions.experimentalGroups` is enabled, also accepts:
  ///
  ///     ExpGroupStart -> '(_:'
  ///
  mutating func lexAtom(
    isInCustomCharacterClass customCC: Bool, priorGroupCount: Int
  ) throws -> AST.Atom? {
    let kind: Located<AST.Atom.Kind>? = try recordLoc { src in
      // Check for not-an-atom, e.g. parser recursion termination
      if src.isEmpty { return nil }
      if !customCC && (src.peek() == ")" || src.peek() == "|") { return nil }
      // TODO: Store customCC in the atom, if that's useful

      // POSIX character property. This is only allowed in a custom character
      // class.
      // TODO: Can we try and recover and diagnose these outside character
      // classes?
      if customCC, let prop = try src.lexPOSIXCharacterProperty()?.value {
        return .property(prop)
      }

      // References that look like groups, e.g (?R), (?1), ...
      if let ref = try src.lexGroupLikeReference() {
        return ref.value
      }

      let char = src.eat()
      switch char {
      case ")", "|":
        if customCC {
          return .char(char)
        }
        fatalError("unreachable")

      // (sometimes) special metacharacters
      case ".": return customCC ? .char(".") : .any
      case "^": return customCC ? .char("^") : .startOfLine
      case "$": return customCC ? .char("$") : .endOfLine

      // Escaped
      case "\\": return try src.expectEscaped(
        isInCustomCharacterClass: customCC,
        priorGroupCount: priorGroupCount).value

      case "]":
        assert(!customCC, "parser should have prevented this")
        fallthrough

      default: return .char(char)
      }
    }
    guard let kind = kind else { return nil }
    return AST.Atom(kind.value, kind.location)
  }

  /// Try to lex the end of a range in a custom character class, which consists
  /// of a '-' character followed by an atom.
  mutating func lexCustomCharClassRangeEnd(
    priorGroupCount: Int
  ) throws -> (dashLoc: SourceLocation, AST.Atom)? {
    // Make sure we don't have a binary operator e.g '--', and the '-' is not
    // ending the custom character class (in which case it is literal).
    let start = currentPosition
    guard peekCCBinOp() == nil && !starts(with: "-]") && tryEat("-") else {
      return nil
    }
    let dashLoc = Location(start ..< currentPosition)
    guard let end = try lexAtom(isInCustomCharacterClass: true,
                                priorGroupCount: priorGroupCount) else {
      return nil
    }
    return (dashLoc, end)
  }
}

