import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { resolve, dirname } from 'node:path';
import test from 'node:test';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const extension = resolve(root, 'SafariExtension');
const manifest = JSON.parse(readFileSync(resolve(extension, 'manifest.json'), 'utf8'));

test('new-tab override and toolbar popup share a local extension', () => {
  assert.equal(manifest.manifest_version, 3);
  assert.equal(manifest.chrome_url_overrides.newtab, 'newtab.html');
  assert.equal(manifest.action.default_popup, 'popup.html');
  assert.equal(manifest.options_ui.page, 'options.html');
  for (const path of ['newtab.html', 'popup.html', 'options.html', manifest.background.service_worker]) {
    assert.ok(existsSync(resolve(extension, path)), `${path} is packaged`);
  }
  assert.equal(manifest.background.type, 'module');
});

test('permissions exclude native access and webpage injection', () => {
  assert.deepEqual(manifest.permissions, ['tabs', 'storage']);
  assert.deepEqual(manifest.host_permissions, ['<all_urls>']);
  for (const key of ['content_scripts', 'externally_connectable', 'web_accessible_resources', 'update_url']) {
    assert.equal(manifest[key], undefined, `${key} is not required`);
  }
  assert.equal(manifest.permissions.includes('nativeMessaging'), false);
  assert.equal(manifest.permissions.includes('history'), false);
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
  for (const filename of ['newtab.html', 'popup.html', 'options.html']) {
    const html = readFileSync(resolve(extension, filename), 'utf8');
    assert.doesNotMatch(html, /<script[^>]+src=["']https?:/i);
    assert.doesNotMatch(html, /\bon\w+\s*=/i);
    assert.doesNotMatch(html, /<style\b/i);
    for (const match of html.matchAll(/(?:src|href)=["']([^"']+\.(?:mjs|css))["']/g)) {
      assert.ok(existsSync(resolve(extension, match[1])), `${filename}: ${match[1]} exists`);
    }
  }
});
