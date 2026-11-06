"""Apply reviewed source overlay to the pinned upstream checkout. No credentials."""
from pathlib import Path
import shutil
import sys

recipe = Path(__file__).resolve().parent.parent
root = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path.cwd()
shutil.copytree(recipe / 'overlay' / 'Glasses', root / 'iPhoneUse' / 'Glasses', dirs_exist_ok=True)
view = root / 'iPhoneUse' / 'Agent' / 'AgentView.swift'
s = view.read_text()
assert '@State private var showGlasses' not in s, 'Overlay already applied'
s = s.replace('@State private var showSettings = false', '@State private var showSettings = false\n    @State private var showGlasses = false')
s = s.replace('.sheet(isPresented: $showSettings)', '.sheet(isPresented: $showGlasses) { GlassesView() }\n        .sheet(isPresented: $showSettings)')
s = s.replace('ToolbarItemGroup(placement: .topBarTrailing) {', 'ToolbarItemGroup(placement: .topBarTrailing) {\n                    Button("Glasses", systemImage: "eyeglasses") { composerFocused = false; showGlasses = true }')
view.write_text(s)
# Prevent simultaneous agent and glasses gestures on the shared developer connection.
agent = root / 'iPhoneUse' / 'Agent' / 'PhoneAgent.swift'
s = agent.read_text()
for signature in ['func run(prompt: String)', 'func runScript(_ script: String)']:
    start = s.find(signature)
    assert start >= 0, signature
    brace = s.index('{', start)
    s = s[:brace+1] + '\n        guard !GlassesBridge.shared.running else { return }' + s[brace+1:]
agent.write_text(s)

project = root / 'iPhoneUse.xcodeproj' / 'project.pbxproj'
s = project.read_text()
assert 'GLASS' not in s
s = s.replace('/* Begin PBXBuildFile section */', '''/* Begin PBXBuildFile section */
        F10000000000000000000001 /* WebRTC in Frameworks */ = {isa = PBXBuildFile; productRef = F10000000000000000000002 /* WebRTC */; };''')
marker = 'A80000000000000000000001 /* Frameworks */ = {'
start = s.index(marker)
idx = s.index('files = (', start) + len('files = (')
s = s[:idx] + '\n                F10000000000000000000001 /* WebRTC in Frameworks */,' + s[idx:]
s = s.replace('name = iPhoneUse;', 'packageProductDependencies = (F10000000000000000000002 /* WebRTC */);\n            name = iPhoneUse;')
s = s.replace('projectRoot = "";', 'projectRoot = "";\n            packageReferences = (F10000000000000000000003 /* WebRTC */);')
s = s.replace('/* Begin XCBuildConfiguration section */', '''/* Begin XCRemoteSwiftPackageReference section */
        F10000000000000000000003 /* WebRTC */ = {
            isa = XCRemoteSwiftPackageReference;
            repositoryURL = "https://github.com/stasel/WebRTC.git";
            requirement = {kind = exactVersion; version = 157.0.0;};
        };
/* End XCRemoteSwiftPackageReference section */
/* Begin XCSwiftPackageProductDependency section */
        F10000000000000000000002 /* WebRTC */ = {
            isa = XCSwiftPackageProductDependency;
            package = F10000000000000000000003 /* WebRTC */;
            productName = WebRTC;
        };
/* End XCSwiftPackageProductDependency section */
/* Begin XCBuildConfiguration section */''')
project.write_text(s)
print('Glasses companion overlay applied')
