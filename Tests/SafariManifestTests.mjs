import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { resolve, dirname } from 'node:path';
import test from 'node:test';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const extension = resolve(root, 'SafariExtension');
const manifest = JSON.parse(readFileSync(resolve(extension, 'manifest.json'), 'utf8'));

test('overlay shortcut and toolbar action preserve Safari native new tabs', () => {
  assert.equal(manifest.manifest_version, 3);
  assert.equal(manifest.version, '1.4.0');
  assert.equal(manifest.chrome_url_overrides, undefined, 'Opening search does not replace Safari New Tab');
  assert.equal(manifest.action.default_popup, 'popup.html', 'The toolbar uses Safari native popup presentation');
  assert.deepEqual(Object.keys(manifest.commands), ['toggle-search']);
  assert.equal(manifest.commands['toggle-search'].suggested_key.mac, 'Command+Shift+Y');
  assert.ok(manifest.commands['toggle-search'].description.trim());
  for (const command of Object.values(manifest.commands)) {
    assert.equal(Object.values(command.suggested_key).includes('Command+T'), false, 'Do not reserve native Cmd+T');
  }
  assert.equal(manifest.options_ui.page, 'options.html');
  for (const path of ['newtab.html', 'popup.html', 'options.html', 'overlay-entry.mjs', 'overlay.js', 'overlay.css', 'overlay-frame.html',
    'overlay-controller.mjs', manifest.background.service_worker]) {
    assert.ok(existsSync(resolve(extension, path)), `${path} is packaged`);
  }
  assert.equal(manifest.background.type, 'module');
});

test('permissions support user-triggered injection without automatic or native access', () => {
  assert.deepEqual(manifest.permissions, ['tabs', 'storage', 'scripting', 'activeTab']);
  assert.deepEqual(manifest.host_permissions, ['<all_urls>']);
  for (const key of ['content_scripts', 'externally_connectable', 'update_url']) {
    assert.equal(manifest[key], undefined, `${key} is not required`);
  }
  assert.equal(manifest.permissions.includes('nativeMessaging'), false);
  assert.equal(manifest.permissions.includes('history'), false);
});

test('only the protected overlay HTML frame is exposed for HTTP(S) embedding', () => {
  assert.equal(manifest.web_accessible_resources.length, 1);
  const resource = manifest.web_accessible_resources[0];
  assert.deepEqual(resource.resources, ['overlay-frame.html']);
  assert.deepEqual(new Set(resource.matches), new Set(['http://*/*', 'https://*/*']));
  assert.equal(resource.extension_ids, undefined);
});

test('injected overlay resources are bundled rather than remotely executable', () => {
  const bundle = readFileSync(resolve(extension, 'overlay.js'), 'utf8');
  assert.ok(bundle.length > 1000, 'The self-contained overlay is not an empty placeholder');
  assert.doesNotMatch(bundle, /\bimport\s*(?:\(|[^;\n]*\bfrom\s*)["']https?:/);
  assert.doesNotMatch(bundle, /\b(?:eval|importScripts)\s*\(|\bnew\s+Function\s*\(/);
});

test('CSP blocks remote code, remote image trackers and insecure service requests', () => {
  const policy = manifest.content_security_policy.extension_pages;
  assert.match(policy, /script-src 'self'/);
  assert.match(policy, /object-src 'none'/);
  assert.match(policy, /connect-src 'self' https:/);
  assert.match(policy, /img-src 'self' data:/);
  assert.match(policy, /style-src 'self'/);
  assert.doesNotMatch(policy, /unsafe-inline|unsafe-eval|http:|\*/);
});

test('every declared icon is a local, nonempty PNG of the declared size', () => {
  for (const dictionary of [manifest.icons, manifest.action.default_icon]) {
    for (const [size, path] of Object.entries(dictionary)) {
      const data = readFileSync(resolve(extension, path));
      assert.ok(data.length > 100);
      assert.deepEqual([...data.subarray(0, 8)], [137, 80, 78, 71, 13, 10, 26, 10]);
      assert.equal(data.readUInt32BE(16), Number(size));
      assert.equal(data.readUInt32BE(20), Number(size));
    }
  }
});

test('HTML entry points use only bundled scripts and styles', () => {
  for (const filename of ['newtab.html', 'popup.html', 'options.html', 'overlay-frame.html']) {
    const html = readFileSync(resolve(extension, filename), 'utf8');
    assert.doesNotMatch(html, /<script[^>]+src=["']https?:/i);
    assert.doesNotMatch(html, /\bon\w+\s*=/i);
    assert.doesNotMatch(html, /<style\b/i);
    for (const match of html.matchAll(/(?:src|href)=["']([^"']+\.(?:mjs|css))["']/g)) {
      assert.ok(existsSync(resolve(extension, match[1])), `${filename}: ${match[1]} exists`);
    }
  }
});
