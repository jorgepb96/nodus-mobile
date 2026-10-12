#!/usr/bin/env python3
"""Execute the actual native catalogue method and its tests without Xcode.
The harness replaces only app/session/storage scaffolding; request state logic is extracted
verbatim from production. It is not native UI or URLSession acceptance.
"""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[2]
source = (root / 'ios/Nodus/AI/NativeLiveChatOptions.swift').read_text()
start = source.index('    func catalogue(provider:String,request:')
end = source.index('    private static func named', start)
method = source[start:end]
tests = (root / 'ios/NodusTests/NativeLiveChatCatalogueTests.swift').read_text()
tests = '\n'.join(line for line in tests.splitlines() if not line.startswith(('import Testing','import NodusKit','@testable import','@Suite','    @Test')))
tests = tests.replace('struct NativeLiveChatCatalogueTests', '@MainActor struct NativeLiveChatCatalogueTests').replace('#expect(', 'precondition(')
scaffold = '''import Foundation
struct APIError:Error { let status:Int;let code:String;let message:String }
extension Error { var isCancellation:Bool { self is CancellationError || (self as? URLError)?.code == .cancelled } }
@MainActor final class NativeLiveChatOptions {
var catalogueRequest=UUID(),catalogLoading=false
var models:[JSONValue]=[],issue:String?,effectiveModel:JSONValue?
init(spaceId:String) {}
'''
runner = '''@main struct CatalogueTestMain {
@MainActor static func main() async throws {
let tests=NativeLiveChatCatalogueTests()
try await tests.latestProvider();try await tests.staleFailure();try await tests.unreadable()
print("3 native catalogue production-method regressions passed; latest provider, stale response/error, unreadable state")
}}
'''
with tempfile.TemporaryDirectory(prefix='nodus-native-catalogue-') as temp:
    fixture=Path(temp)/'Catalogue.swift';fixture.write_text(scaffold+method+'}\n'+tests+'\n'+runner)
    binary=Path(temp)/'catalogue'
    core=root/'ios/Packages/NodusKit/Sources/NodusKit/Core'
    subprocess.run(['swiftc','-swift-version','6','-parse-as-library',str(core/'JSONValue.swift'),str(fixture),'-o',str(binary)],check=True)
    subprocess.run([str(binary)],check=True,timeout=30)
