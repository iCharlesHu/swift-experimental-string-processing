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

public struct Program<Input: Collection> where Input.Element: Equatable {
  public typealias ConsumeFunction = (Input, Range<Input.Index>) -> Input.Index?
  public typealias AssertionFunction =
    (Input, Input.Index, Range<Input.Index>) -> Bool
  var instructions: InstructionList<Instruction>

  var staticElements: [Input.Element]
  var staticSequences: [[Input.Element]]
  var staticStrings: [String]
  var staticConsumeFunctions: [ConsumeFunction]
  var staticAssertionFunctions: [AssertionFunction]

  var registerInfo: RegisterInfo

  var enableTracing: Bool = false
}

extension Program: CustomStringConvertible {
  public var description: String {
    var result = """
    Elements: \(staticElements)
    Strings: \(staticStrings)

    """
    if !staticConsumeFunctions.isEmpty {
      result += "Consume functions: \(staticConsumeFunctions)"
    }

    // TODO: Extract into formatting code

    for idx in instructions.indices {
      let inst = instructions[idx]
      result += "[\(idx.rawValue)] \(inst)"
      if let sp = inst.stringRegister {
        result += " // \(staticStrings[sp.rawValue])"
      }
      if let ia = inst.instructionAddress {
        result += " // \(instructions[ia])"
      }
      result += "\n"
    }
    return result
  }
}
