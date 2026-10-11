import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { basename, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const projectPath = resolve(root, 'SafariApp/Tab Scout/Tab Scout.xcodeproj/project.pbxproj');
const project = JSON.parse(execFileSync('/usr/bin/plutil', ['-convert', 'json', '-o', '-', projectPath], { encoding: 'utf8' }));
const manifest = JSON.parse(readFileSync(resolve(root, 'SafariExtension/manifest.json'), 'utf8'));

function validateProject(value) {
  assert.equal(Number(value.objectVersion), 56, 'Use the stable Xcode 14 project format');
  assert.equal(Number(value.archiveVersion), 1);
  const description = value.objects[value.rootObject];
  assert.equal(description.isa, 'PBXProject');
  assert.equal(description.compatibilityVersion, 'Xcode 14.0');
  assert.equal(description.preferredProjectObjectVersion, undefined);
  assert.equal(description.minimizedProjectReferenceProxies, undefined);
  assert.equal(value.validationLevel, undefined);
  const copies = Object.values(value.objects).filter(object => object.isa === 'PBXCopyFilesBuildPhase');
  assert.equal(copies.length, 1);
  assert.equal(Number(copies[0].dstSubfolderSpec), 13, 'Embed the extension in Contents/PlugIns');
  assert.equal(copies[0].dstSubfolder, undefined, 'Do not use the future destination enum');
  for (const object of Object.values(value.objects)) {
    assert.equal(object.isa.startsWith('PBXFileSystemSynchronized'), false, 'Use explicit resource groups');
    if (object.isa === 'PBXFileReference') {
      assert.notEqual(object.sourceTree, '<absolute>');
      assert.doesNotMatch(object.path, /^(?:\/|[a-z]:)/i, 'References must survive a fresh checkout');
    }
  }
}

test('Safari project uses a portable format and legacy PlugIns destination', () => {
  validateProject(project);
});

test('future project headers are rejected before invoking Xcode', () => {
  const fixture = structuredClone(project);
  fixture.objectVersion = '110';
  assert.throws(() => validateProject(fixture), /stable Xcode 14/);
});

test('a preferred future project format cannot silently reintroduce the regression', () => {
  const fixture = structuredClone(project);
  fixture.objects[fixture.rootObject].preferredProjectObjectVersion = '110';
  assert.throws(() => validateProject(fixture));
});

test('future copy destination syntax is rejected', () => {
  const fixture = structuredClone(project);
  const copy = Object.values(fixture.objects).find(object => object.isa === 'PBXCopyFilesBuildPhase');
  delete copy.dstSubfolderSpec;
  copy.dstSubfolder = 'PlugIns';
  assert.throws(() => validateProject(fixture), /Contents\/PlugIns/);
});

test('filesystem synchronized groups and machine-specific paths are rejected', () => {
  const synchronized = structuredClone(project);
  synchronized.objects.FIXTURE = { isa: 'PBXFileSystemSynchronizedRootGroup' };
  assert.throws(() => validateProject(synchronized), /explicit resource groups/);
  const absolute = structuredClone(project);
  Object.values(absolute.objects).find(object => object.isa === 'PBXFileReference').path = '/Users/developer/file.swift';
  assert.throws(() => validateProject(absolute), /fresh checkout/);
});

test('both targets remain sandboxed in Debug and Release without legacy permissions', () => {
  const configurations = Object.values(project.objects).filter(object => object.isa === 'XCBuildConfiguration' && object.buildSettings.PRODUCT_BUNDLE_IDENTIFIER);
  assert.equal(configurations.length, 4);
  for (const { buildSettings } of configurations) {
    assert.equal(buildSettings.ENABLE_APP_SANDBOX, 'YES');
    assert.equal(buildSettings.CODE_SIGN_ENTITLEMENTS, '../Entitlements.plist');
    assert.equal(buildSettings.ENABLE_DEBUG_DYLIB, 'NO');
    assert.equal(buildSettings.ENABLE_OUTGOING_NETWORK_CONNECTIONS, undefined);
    assert.equal(buildSettings.ENABLE_USER_SELECTED_FILES, undefined);
    assert.equal(buildSettings.INFOPLIST_KEY_NSMainStoryboardFile, undefined);
    assert.ok(['local.tabscout.safari', 'local.tabscout.safari.Extension'].includes(buildSettings.PRODUCT_BUNDLE_IDENTIFIER));
  }
});

test('direct Xcode builds use the same version as the extension manifest', () => {
  const configurations = Object.values(project.objects).filter(object => object.isa === 'XCBuildConfiguration'
    && object.buildSettings.PRODUCT_BUNDLE_IDENTIFIER);
  assert.equal(configurations.length, 4);
  for (const { buildSettings } of configurations) {
    assert.equal(buildSettings.MARKETING_VERSION, manifest.version);
  }
});

test('the Xcode extension resource phase includes the overlay and protected frame dependencies', () => {
  const target = Object.values(project.objects).find(object => object.isa === 'PBXNativeTarget'
    && object.productType === 'com.apple.product-type.app-extension');
  const resourcePhase = target.buildPhases.map(id => project.objects[id])
    .find(object => object.isa === 'PBXResourcesBuildPhase');
  const references = resourcePhase.files.map(id => project.objects[project.objects[id].fileRef]);
  if (references.some(reference => basename(reference.path) === 'SafariExtension'
    && (reference.lastKnownFileType === 'folder' || reference.explicitFileType === 'folder'))) return;
  const resources = new Set(references.map(reference => basename(reference.path)));
  const required = ['manifest.json', 'overlay.js', 'overlay-entry.mjs', 'overlay-controller.mjs', 'overlay.css', 'overlay-frame.html',
    'background.mjs', 'search.mjs', 'core.mjs', 'services.mjs', 'ui.css', 'popup.html', 'options.html', 'icons'];
  const frameHTML = readFileSync(resolve(root, 'SafariExtension/overlay-frame.html'), 'utf8');
  for (const match of frameHTML.matchAll(/(?:src|href)=["']([^"']+\.(?:mjs|js|css))["']/g)) {
    required.push(basename(match[1]));
  }
  for (const filename of required) assert.ok(resources.has(filename), `${filename} must survive a Store archive`);
});

test('the storyboard-free setup app explicitly retains and attaches its delegate', () => {
  const source = readFileSync(resolve(root, 'SafariApp/Host/AppDelegate.swift'), 'utf8');
  assert.match(source, /static func main\(\)/);
  assert.match(source, /application\.delegate = delegate/);
  assert.match(source, /withExtendedLifetime\(delegate\)/);
  assert.match(source, /application\.run\(\)/);
});
