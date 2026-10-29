"""Generate plist files and a dependency-free, two-target Xcode project."""
import hashlib
import pathlib
import plistlib
import sys

ROOT = pathlib.Path(sys.argv[2] if len(sys.argv) > 2 else pathlib.Path(__file__).resolve().parents[1])
APP_ID = 'com.example.TodaySchedule'
WIDGET_ID = APP_ID + '.Widget'


def write_plist(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(plistlib.dumps(value, sort_keys=False))


def info(widget=False, local=False):
    data = {
        'CFBundleDevelopmentRegion': 'zh_CN',
        'CFBundleDisplayName': '今日事项',
        'CFBundleName': '今日事项',
        'CFBundleIdentifier': WIDGET_ID if widget else APP_ID,
        'CFBundleExecutable': 'TodayScheduleWidget' if widget else 'TodaySchedule',
        'CFBundlePackageType': 'XPC!' if widget else 'APPL',
        'CFBundleShortVersionString': '1.3',
        'CFBundleVersion': '4',
        'CFBundleInfoDictionaryVersion': '6.0',
        'CFBundleSupportedPlatforms': ['MacOSX'],
        'DTPlatformName': 'macosx',
        'LSMinimumSystemVersion': '14.0',
    }
    if widget:
        data['NSExtension'] = {'NSExtensionPointIdentifier': 'com.apple.widgetkit-extension'}
    else:
        data['NSPrincipalClass'] = 'NSApplication'
        if (ROOT / 'Config/AppIcon.icns').exists(): data['CFBundleIconFile'] = 'AppIcon'
        data['NSAppleEventsUsageDescription'] = '将小组件的完成标记同步到正在打开的 Excel 日程表，并自动保存整份表格。'
        data['CFBundleURLTypes'] = [{'CFBundleURLName': APP_ID, 'CFBundleURLSchemes': ['todayschedule']}]
        data['NSDesktopFolderUsageDescription'] = '读取你选择的 Excel 日程表，并写回已完成事项的删除线标记。'
    if local:
        data['LocalDataDirectory'] = str(ROOT / '.local-data')
    else:
        data['ScheduleAppGroup'] = '$(TeamIdentifierPrefix)com.example.TodaySchedule'
    return data


if sys.argv[1] == 'local':
    app = ROOT / 'outputs/今日事项.app/Contents'
    write_plist(app / 'Info.plist', info(local=True))
    write_plist(app / 'PlugIns/TodayScheduleWidget.appex/Contents/Info.plist', info(widget=True, local=True))
    write_plist(ROOT / 'work/Widget.local.entitlements', {
        'com.apple.security.app-sandbox': True,
        'com.apple.security.temporary-exception.files.absolute-path.read-write': [str(ROOT / '.local-data') + '/'],
    })
    sys.exit()

for widget, prefix in [(False, 'App'), (True, 'Widget')]:
    write_plist(ROOT / f'Config/{prefix}-Info.plist', info(widget))
    entitlements = {
        'com.apple.security.app-sandbox': True,
        'com.apple.security.application-groups': ['$(TeamIdentifierPrefix)com.example.TodaySchedule'],
    }
    if not widget:
        entitlements['com.apple.security.files.user-selected.read-write'] = True
        entitlements['com.apple.security.files.bookmarks.app-scope'] = True
        entitlements['com.apple.security.automation.apple-events'] = True
        entitlements['com.apple.security.temporary-exception.apple-events'] = ['com.microsoft.Excel']
    write_plist(ROOT / f'Config/{prefix}.entitlements', entitlements)


def ident(name):
    return hashlib.sha1(name.encode()).hexdigest()[:24].upper()


def quote(s):
    return '"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"'


objects = []


def obj(name, content):
    objects.append(f'\t\t{ident(name)} = {{ {content} }};')
    return ident(name)


shared = ['Sources/Shared/Schedule.swift', 'Sources/Shared/TodayCard.swift']
app_sources = shared + ['Sources/App/XLSXReader.swift', 'Sources/App/XLSXCompletionWriter.swift', 'Sources/App/CompletionStrikeStore.swift', 'Sources/App/ExcelLiveWriter.swift', 'Sources/App/TodayScheduleApp.swift']
widget_sources = shared + ['Sources/Widget/TodayWidget.swift']
files = list(dict.fromkeys(app_sources + widget_sources))
for f in files:
    obj(f, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {quote(f)}; sourceTree = "<group>";')
for target, sources in [('App', app_sources), ('Widget', widget_sources)]:
    for source in sources:
        obj(target + source, f'isa = PBXBuildFile; fileRef = {ident(source)};')
    obj(target + 'Sources', 'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (' + ','.join(ident(target+s) for s in sources) + '); runOnlyForDeploymentPostprocessing = 0;')
    obj(target + 'Frameworks', 'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')

has_icon = (ROOT / 'Config/AppIcon.icns').exists()
if has_icon:
    obj('AppIcon', 'isa = PBXFileReference; lastKnownFileType = image.icns; path = Config/AppIcon.icns; sourceTree = "<group>";')
    obj('AppIconBuild', f'isa = PBXBuildFile; fileRef = {ident("AppIcon")};')
    obj('AppResources', f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({ident("AppIconBuild")}); runOnlyForDeploymentPostprocessing = 0;')

obj('AppProduct', 'isa = PBXFileReference; explicitFileType = wrapper.application; path = TodaySchedule.app; sourceTree = BUILT_PRODUCTS_DIR;')
obj('WidgetProduct', 'isa = PBXFileReference; explicitFileType = "wrapper.app-extension"; path = TodayScheduleWidget.appex; sourceTree = BUILT_PRODUCTS_DIR;')
obj('Products', f'isa = PBXGroup; children = ({ident("AppProduct")}, {ident("WidgetProduct")}); name = Products; sourceTree = "<group>";')
obj('MainGroup', 'isa = PBXGroup; children = (' + ','.join(ident(f) for f in files) + (',' + ident('AppIcon') if has_icon else '') + ',' + ident('Products') + '); sourceTree = "<group>";')
obj('EmbedBuild', f'isa = PBXBuildFile; fileRef = {ident("WidgetProduct")}; settings = {{ ATTRIBUTES = (RemoveHeadersOnCopy,); }};')
obj('Embed', f'isa = PBXCopyFilesBuildPhase; buildActionMask = 2147483647; dstPath = ""; dstSubfolderSpec = 13; files = ({ident("EmbedBuild")}); name = "Embed App Extensions"; runOnlyForDeploymentPostprocessing = 0;')
obj('Proxy', f'isa = PBXContainerItemProxy; containerPortal = {ident("Project")}; proxyType = 1; remoteGlobalIDString = {ident("WidgetTarget")}; remoteInfo = TodayScheduleWidget;')
obj('Dependency', f'isa = PBXTargetDependency; target = {ident("WidgetTarget")}; targetProxy = {ident("Proxy")};')

for target in ['App', 'Widget', 'Project']:
    for variant in ['Debug', 'Release']:
        settings = {
            'MACOSX_DEPLOYMENT_TARGET': '14.0', 'SDKROOT': 'macosx', 'SWIFT_VERSION': '5.0',
            'SWIFT_OPTIMIZATION_LEVEL': '-Onone' if variant == 'Debug' else '-O',
            'CLANG_ENABLE_MODULES': 'YES',
        }
        if target != 'Project':
            if target == 'App' and variant == 'Debug':
                settings['COPY_PHASE_STRIP'] = 'NO'
            settings.update({
                'PRODUCT_NAME': 'TodaySchedule' if target == 'App' else 'TodayScheduleWidget',
                'PRODUCT_BUNDLE_IDENTIFIER': APP_ID if target == 'App' else WIDGET_ID,
                'INFOPLIST_FILE': f'Config/{target}-Info.plist',
                'CODE_SIGN_ENTITLEMENTS': f'Config/{target}.entitlements',
                'CODE_SIGN_STYLE': 'Automatic', 'DEVELOPMENT_TEAM': '',
                'ENABLE_HARDENED_RUNTIME': 'YES',
                'LD_RUNPATH_SEARCH_PATHS': '$(inherited) @executable_path/../Frameworks @executable_path/../../../../Frameworks',
            })
            if target == 'Widget':
                settings.update({'APPLICATION_EXTENSION_API_ONLY': 'YES', 'SKIP_INSTALL': 'YES'})
        setting_text = ' '.join(k + ' = ' + quote(v) + ';' for k, v in settings.items())
        obj(target + variant, f'isa = XCBuildConfiguration; buildSettings = {{ {setting_text} }}; name = {variant};')
    obj(target + 'Config', f'isa = XCConfigurationList; buildConfigurations = ({ident(target+"Debug")},{ident(target+"Release")}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')

for target in ['App', 'Widget']:
    app = target == 'App'
    phases = [ident(target + 'Sources'), ident(target + 'Frameworks')] + ([ident('AppResources')] if app and has_icon else []) + ([ident('Embed')] if app else [])
    obj(target + 'Target', f'isa = PBXNativeTarget; buildConfigurationList = {ident(target+"Config")}; buildPhases = ({",".join(phases)}); buildRules = (); dependencies = ({ident("Dependency") if app else ""}); name = {"TodaySchedule" if app else "TodayScheduleWidget"}; productName = {"TodaySchedule" if app else "TodayScheduleWidget"}; productReference = {ident(target+"Product")}; productType = {quote("com.apple.product-type.application" if app else "com.apple.product-type.app-extension")};')
obj('Project', f'isa = PBXProject; attributes = {{ LastSwiftUpdateCheck = 1600; LastUpgradeCheck = 1600; }}; buildConfigurationList = {ident("ProjectConfig")}; compatibilityVersion = "Xcode 14.0"; developmentRegion = zh_CN; hasScannedForEncodings = 0; knownRegions = (zh_CN,en,Base); mainGroup = {ident("MainGroup")}; productRefGroup = {ident("Products")}; projectDirPath = ""; projectRoot = ""; targets = ({ident("AppTarget")},{ident("WidgetTarget")});')
project = ROOT / 'TodaySchedule.xcodeproj'
project.mkdir(exist_ok=True)
(project / 'project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n' + '\n'.join(objects) + '\n}; rootObject = ' + ident('Project') + '; }\n')
scheme = project / 'xcshareddata/xcschemes'
scheme.mkdir(parents=True, exist_ok=True)
(scheme / 'TodaySchedule.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
 <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ident('AppTarget')}" BuildableName="TodaySchedule.app" BlueprintName="TodaySchedule" ReferencedContainer="container:TodaySchedule.xcodeproj"/></BuildActionEntry>
 </BuildActionEntries></BuildAction>
 <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ident('AppTarget')}" BuildableName="TodaySchedule.app" BlueprintName="TodaySchedule" ReferencedContainer="container:TodaySchedule.xcodeproj"/></BuildableProductRunnable></LaunchAction>
 <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
print(project)
