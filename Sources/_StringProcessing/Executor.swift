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

import _MatchingEngine

public struct Executor {
  // TODO: consider let, for now lets us toggle tracing
  var engine: Engine<String>

  init(program: RegexProgram, enablesTracing: Bool = false) {
    self.engine = Engine(program.program, enableTracing: enablesTracing)
  }

  public func execute(
    input: String,
    in range: Range<String.Index>,
    mode: MatchMode = .wholeString
  ) -> MatchResult? {
    engine.consume(
      input, in: range, matchMode: mode.loweredMatchMode
    ).map { endIndex in
      MatchResult(range.lowerBound..<endIndex, .void)
    }
  }
}

// Backward compatibility layer. To be removed when we deprecate legacy
// components.
extension Executor: VirtualMachine {
  static let motto = "Executor"

  init(program: RegexProgram) {
    self.init(program: program, enablesTracing: false)
  }
}

extension _StringProcessing.MatchMode {
  var loweredMatchMode: _MatchingEngine.MatchMode {
    switch self {
    case .wholeString:
      return .full
    case .partialFromFront:
      return .prefix
    }
  }
}
