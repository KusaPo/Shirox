"""Generate the checked-in Xcode project without third-party dependencies."""
from pathlib import Path
import hashlib

root = Path(__file__).resolve().parents[1]
def uid(text): return hashlib.sha1(text.encode()).hexdigest()[:24].upper()
objects = []
def add(name, text):
    objects.append(f'{uid(name)} = {{ {text} }};')
    return uid(name)
def refs(names): return '(' + ','.join(uid(n) for n in names) + ',)'

app = sorted(root.glob('Kairo/Sources/*.swift'))
tests = sorted(root.glob('KairoTests/*.swift'))
for file in app + tests:
    path = file.relative_to(root).as_posix()
    add(path, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "{path}"; sourceTree = SOURCE_ROOT;')
    add('build:' + path, f'isa = PBXBuildFile; fileRef = {uid(path)};')
add('product', 'isa = PBXFileReference; explicitFileType = wrapper.application; path = Kairo.app; sourceTree = BUILT_PRODUCTS_DIR;')
add('testproduct', 'isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = KairoTests.xctest; sourceTree = BUILT_PRODUCTS_DIR;')
add('appgroup', f'isa = PBXGroup; name = App; children = {refs([p.relative_to(root).as_posix() for p in app])}; sourceTree = "<group>";')
add('testgroup', f'isa = PBXGroup; name = Tests; children = {refs([p.relative_to(root).as_posix() for p in tests])}; sourceTree = "<group>";')
add('products', f'isa = PBXGroup; name = Products; children = {refs(["product", "testproduct"])}; sourceTree = "<group>";')
add('rootgroup', f'isa = PBXGroup; children = {refs(["appgroup", "testgroup", "products"])}; sourceTree = "<group>";')
for prefix, files in [('app', app), ('tests', tests)]:
    add(prefix + 'sources', f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = {refs(["build:"+p.relative_to(root).as_posix() for p in files])}; runOnlyForDeploymentPostprocessing = 0;')
    for phase, kind in [('frameworks', 'PBXFrameworksBuildPhase'), ('resources', 'PBXResourcesBuildPhase')]:
        add(prefix + phase, f'isa = {kind}; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
for prefix in ['project', 'app', 'tests']:
    for mode in ['Debug', 'Release']:
        settings = 'IPHONEOS_DEPLOYMENT_TARGET = 17.0; SDKROOT = iphoneos; SWIFT_VERSION = 5.0; CLANG_ENABLE_MODULES = YES; '
        if prefix == 'project':
            settings += 'SWIFT_OPTIMIZATION_LEVEL = "-Onone"; ENABLE_TESTABILITY = YES; DEBUG_INFORMATION_FORMAT = dwarf; ' if mode == 'Debug' else 'SWIFT_OPTIMIZATION_LEVEL = "-O"; DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym"; '
        else:
            settings += 'TARGETED_DEVICE_FAMILY = "1,2"; CODE_SIGN_STYLE = Automatic; DEVELOPMENT_TEAM = ""; PRODUCT_NAME = "$(TARGET_NAME)"; '
            settings += 'LD_RUNPATH_SEARCH_PATHS = ("$(inherited)","@executable_path/Frameworks",); '
            if prefix == 'app': settings += 'PRODUCT_BUNDLE_IDENTIFIER = net.kusapo.kairo; INFOPLIST_FILE = Kairo/Resources/Info.plist; GENERATE_INFOPLIST_FILE = NO; '
            else: settings += 'PRODUCT_BUNDLE_IDENTIFIER = net.kusapo.kairo.tests; GENERATE_INFOPLIST_FILE = YES; TEST_HOST = "$(BUILT_PRODUCTS_DIR)/Kairo.app/Kairo"; BUNDLE_LOADER = "$(TEST_HOST)"; '
        add(prefix + mode, f'isa = XCBuildConfiguration; buildSettings = {{ {settings} }}; name = {mode};')
    add(prefix + 'configs', f'isa = XCConfigurationList; buildConfigurations = {refs([prefix+"Debug", prefix+"Release"])}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
add('testproxy', f'isa = PBXContainerItemProxy; containerPortal = {uid("project")}; proxyType = 1; remoteGlobalIDString = {uid("apptarget")}; remoteInfo = Kairo;')
add('testdependency', f'isa = PBXTargetDependency; target = {uid("apptarget")}; targetProxy = {uid("testproxy")};')
add('apptarget', f'isa = PBXNativeTarget; buildConfigurationList = {uid("appconfigs")}; buildPhases = {refs(["appsources","appframeworks","appresources"])}; buildRules = (); dependencies = (); name = Kairo; productName = Kairo; productReference = {uid("product")}; productType = "com.apple.product-type.application";')
add('testtarget', f'isa = PBXNativeTarget; buildConfigurationList = {uid("testsconfigs")}; buildPhases = {refs(["testssources","testsframeworks","testsresources"])}; buildRules = (); dependencies = {refs(["testdependency"])}; name = KairoTests; productName = KairoTests; productReference = {uid("testproduct")}; productType = "com.apple.product-type.bundle.unit-test";')
add('project', f'isa = PBXProject; attributes = {{ LastUpgradeCheck = 1600; }}; buildConfigurationList = {uid("projectconfigs")}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; knownRegions = (en,Base,); mainGroup = {uid("rootgroup")}; productRefGroup = {uid("products")}; projectDirPath = ""; projectRoot = ""; targets = {refs(["apptarget","testtarget"])};')
project = root / 'Kairo.xcodeproj'
project.mkdir(exist_ok=True)
(project / 'project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n' + '\n'.join(objects) + f'\n}}; rootObject = {uid("project")}; }}\n')
scheme = project / 'xcshareddata/xcschemes/Kairo.xcscheme'
scheme.parent.mkdir(parents=True, exist_ok=True)
def reference(target, name, product): return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid(target)}" BuildableName="{product}" BlueprintName="{name}" ReferencedContainer="container:Kairo.xcodeproj"/>'
appref = reference('apptarget','Kairo','Kairo.app')
testref = reference('testtarget','KairoTests','KairoTests.xctest')
scheme.write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.7">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{appref}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{testref}</TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{appref}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{appref}</BuildableProductRunnable></ProfileAction><AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')
print('Generated', project)
