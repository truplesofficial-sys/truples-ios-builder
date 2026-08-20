'use strict';

var core = require('@capacitor/core');

/*
 * Maintains navigation history across Capgo-controlled reloads when keepUrlPathAfterReload is enabled.
 */
const KEEP_FLAG_KEY = '__capgo_keep_url_path_after_reload';
const HISTORY_STORAGE_KEY = '__capgo_history_stack__';
const MAX_STACK_ENTRIES = 100;
const isBrowser = typeof window !== 'undefined' && typeof document !== 'undefined' && typeof history !== 'undefined';
if (isBrowser) {
    const win = window;
    if (!win.__capgoHistoryPatched) {
        win.__capgoHistoryPatched = true;
        const isFeatureConfigured = () => {
            try {
                if (win.__capgoKeepUrlPathAfterReload) {
                    return true;
                }
            }
            catch (err) {
                // ignore access issues
            }
            try {
                return window.localStorage.getItem(KEEP_FLAG_KEY) === '1';
            }
            catch (err) {
                return false;
            }
        };
        const readStored = () => {
            try {
                const raw = window.sessionStorage.getItem(HISTORY_STORAGE_KEY);
                if (!raw) {
                    return { stack: [], index: -1 };
                }
                const parsed = JSON.parse(raw);
                if (!parsed || !Array.isArray(parsed.stack) || typeof parsed.index !== 'number') {
                    return { stack: [], index: -1 };
                }
                return parsed;
            }
            catch (err) {
                return { stack: [], index: -1 };
            }
        };
        const writeStored = (stack, index) => {
            try {
                window.sessionStorage.setItem(HISTORY_STORAGE_KEY, JSON.stringify({ stack, index }));
            }
            catch (err) {
                // Storage might be unavailable; fail silently.
            }
        };
        const clearStored = () => {
            try {
                window.sessionStorage.removeItem(HISTORY_STORAGE_KEY);
            }
            catch (err) {
                // ignore
            }
        };
        const normalize = (url) => {
            try {
                const base = url !== null && url !== void 0 ? url : window.location.href;
                const parsed = new URL(base instanceof URL ? base.toString() : base, window.location.href);
                return `${parsed.pathname}${parsed.search}${parsed.hash}`;
            }
            catch (err) {
                return null;
            }
        };
        const trimStack = (stack, index) => {
            if (stack.length <= MAX_STACK_ENTRIES) {
                return { stack, index };
            }
            const start = stack.length - MAX_STACK_ENTRIES;
            const trimmed = stack.slice(start);
            const adjustedIndex = Math.max(0, index - start);
            return { stack: trimmed, index: adjustedIndex };
        };
        const runWhenReady = (fn) => {
            if (document.readyState === 'complete' || document.readyState === 'interactive') {
                fn();
            }
            else {
                window.addEventListener('DOMContentLoaded', fn, { once: true });
            }
        };
        let featureActive = false;
        let isRestoring = false;
        let restoreScheduled = false;
        const ensureCurrentTracked = () => {
            if (!featureActive) {
                return;
            }
            const stored = readStored();
            const current = normalize();
            if (!current) {
                return;
            }
            if (stored.stack.length === 0) {
                stored.stack.push(current);
                stored.index = 0;
                writeStored(stored.stack, stored.index);
                return;
            }
            if (stored.index < 0 || stored.index >= stored.stack.length) {
                stored.index = stored.stack.length - 1;
            }
            if (stored.stack[stored.index] !== current) {
                stored.stack[stored.index] = current;
                writeStored(stored.stack, stored.index);
            }
        };
        const record = (url, replace) => {
            if (!featureActive || isRestoring) {
                return;
            }
            const normalized = normalize(url);
            if (!normalized) {
                return;
            }
            let { stack, index } = readStored();
            if (stack.length === 0) {
                stack.push(normalized);
                index = stack.length - 1;
            }
            else if (replace) {
                if (index < 0 || index >= stack.length) {
                    index = stack.length - 1;
                }
                stack[index] = normalized;
            }
            else {
                if (index >= stack.length - 1) {
                    stack.push(normalized);
                    index = stack.length - 1;
                }
                else {
                    stack = stack.slice(0, index + 1);
                    stack.push(normalized);
                    index = stack.length - 1;
                }
            }
            ({ stack, index } = trimStack(stack, index));
            writeStored(stack, index);
        };
        const restoreHistory = () => {
            if (!featureActive || isRestoring) {
                return;
            }
            const stored = readStored();
            if (stored.stack.length === 0) {
                ensureCurrentTracked();
                return;
            }
            const targetIndex = stored.index >= 0 && stored.index < stored.stack.length ? stored.index : stored.stack.length - 1;
            const normalizedCurrent = normalize();
            if (stored.stack.length === 1 && normalizedCurrent === stored.stack[0]) {
                return;
            }
            const firstEntry = stored.stack[0];
            if (!firstEntry) {
                return;
            }
            isRestoring = true;
            try {
                history.replaceState(history.state, document.title, firstEntry);
                for (let i = 1; i < stored.stack.length; i += 1) {
                    history.pushState(history.state, document.title, stored.stack[i]);
                }
            }
            catch (err) {
                isRestoring = false;
                return;
            }
            isRestoring = false;
            const currentIndex = stored.stack.length - 1;
            const offset = targetIndex - currentIndex;
            if (offset !== 0) {
                history.go(offset);
            }
            else {
                history.replaceState(history.state, document.title, stored.stack[targetIndex]);
                window.dispatchEvent(new PopStateEvent('popstate'));
            }
        };
        const scheduleRestore = () => {
            if (!featureActive || restoreScheduled) {
                return;
            }
            restoreScheduled = true;
            runWhenReady(() => {
                restoreScheduled = false;
                restoreHistory();
            });
        };
        let originalPushState = null;
        let originalReplaceState = null;
        const popstateHandler = () => {
            if (!featureActive || isRestoring) {
                return;
            }
            const normalized = normalize();
            if (!normalized) {
                return;
            }
            const stored = readStored();
            const idx = stored.stack.lastIndexOf(normalized);
            if (idx >= 0) {
                stored.index = idx;
            }
            else {
                stored.stack.push(normalized);
                stored.index = stored.stack.length - 1;
            }
            const trimmed = trimStack(stored.stack, stored.index);
            writeStored(trimmed.stack, trimmed.index);
        };
        const patchHistory = () => {
            if (originalPushState && originalReplaceState) {
                return;
            }
            originalPushState = history.pushState;
            originalReplaceState = history.replaceState;
            history.pushState = function pushStatePatched(state, title, url) {
                const result = originalPushState === null || originalPushState === void 0 ? void 0 : originalPushState.call(history, state, title, url);
                record(url, false);
                return result;
            };
            history.replaceState = function replaceStatePatched(state, title, url) {
                const result = originalReplaceState === null || originalReplaceState === void 0 ? void 0 : originalReplaceState.call(history, state, title, url);
                record(url, true);
                return result;
            };
            window.addEventListener('popstate', popstateHandler);
        };
        const unpatchHistory = () => {
            if (originalPushState) {
                history.pushState = originalPushState;
                originalPushState = null;
            }
            if (originalReplaceState) {
                history.replaceState = originalReplaceState;
                originalReplaceState = null;
            }
            window.removeEventListener('popstate', popstateHandler);
        };
        const setFeatureActive = (enabled) => {
            if (featureActive === enabled) {
                if (featureActive) {
                    ensureCurrentTracked();
                    scheduleRestore();
                }
                return;
            }
            featureActive = enabled;
            if (featureActive) {
                patchHistory();
                ensureCurrentTracked();
                scheduleRestore();
            }
            else {
                unpatchHistory();
                clearStored();
            }
        };
        window.addEventListener('CapacitorUpdaterKeepUrlPathAfterReload', (event) => {
            var _a;
            const evt = event;
            const enabled = (_a = evt === null || evt === void 0 ? void 0 : evt.detail) === null || _a === void 0 ? void 0 : _a.enabled;
            if (typeof enabled === 'boolean') {
                win.__capgoKeepUrlPathAfterReload = enabled;
                setFeatureActive(enabled);
            }
            else {
                win.__capgoKeepUrlPathAfterReload = true;
                setFeatureActive(true);
            }
        });
        setFeatureActive(isFeatureConfigured());
    }
}

/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */
/**
 * Update availability status.
 *
 * @since 8.0.0
 */
exports.AppUpdateAvailability = void 0;
(function (AppUpdateAvailability) {
    /**
     * Update availability is unknown.
     * This typically means the check hasn't completed or failed.
     */
    AppUpdateAvailability[AppUpdateAvailability["UNKNOWN"] = 0] = "UNKNOWN";
    /**
     * No update is available.
     * The installed version is the latest.
     */
    AppUpdateAvailability[AppUpdateAvailability["UPDATE_NOT_AVAILABLE"] = 1] = "UPDATE_NOT_AVAILABLE";
    /**
     * An update is available for download.
     */
    AppUpdateAvailability[AppUpdateAvailability["UPDATE_AVAILABLE"] = 2] = "UPDATE_AVAILABLE";
    /**
     * An update is currently being downloaded or installed.
     */
    AppUpdateAvailability[AppUpdateAvailability["UPDATE_IN_PROGRESS"] = 3] = "UPDATE_IN_PROGRESS";
})(exports.AppUpdateAvailability || (exports.AppUpdateAvailability = {}));
/**
 * Installation status for flexible updates (Android only).
 *
 * @since 8.0.0
 */
exports.FlexibleUpdateInstallStatus = void 0;
(function (FlexibleUpdateInstallStatus) {
    /**
     * Unknown install status.
     */
    FlexibleUpdateInstallStatus[FlexibleUpdateInstallStatus["UNKNOWN"] = 0] = "UNKNOWN";
    /**
     * Download is pending and will start soon.
     */
    FlexibleUpdateInstallStatus[FlexibleUpdateInstallStatus["PENDING"] = 1] = "PENDING";
    /**
     * Download is in progress.
     * Check `bytesDownloaded` and `totalBytesToDownload` for progress.
     */
    FlexibleUpdateInstallStatus[FlexibleUpdateInstallStatus["DOWNLOADING"] = 2] = "DOWNLOADING";
    /**
     * The update is being installed.
     */
    FlexibleUpdateInstallStatus[FlexibleUpdateInstallStatus["INSTALLING"] = 3] = "INSTALLING";
    /**
     * The update has been installed.
     * The app needs to be restarted to use the new version.
     */
    FlexibleUpdateInstallStatus[FlexibleUpdateInstallStatus["INSTALLED"] = 4] = "INSTALLED";
    /**
     * The update failed to download or install.
     */
    FlexibleUpdateInstallStatus[FlexibleUpdateInstallStatus["FAILED"] = 5] = "FAILED";
    /**
     * The update was canceled by the user.
     */
    FlexibleUpdateInstallStatus[FlexibleUpdateInstallStatus["CANCELED"] = 6] = "CANCELED";
    /**
     * The update has been downloaded and is ready to install.
     * Call {@link CapacitorUpdaterPlugin.completeFlexibleUpdate} to install.
     */
    FlexibleUpdateInstallStatus[FlexibleUpdateInstallStatus["DOWNLOADED"] = 11] = "DOWNLOADED";
})(exports.FlexibleUpdateInstallStatus || (exports.FlexibleUpdateInstallStatus = {}));
/**
 * Result codes for app update operations.
 *
 * @since 8.0.0
 */
exports.AppUpdateResultCode = void 0;
(function (AppUpdateResultCode) {
    /**
     * The update completed successfully.
     */
    AppUpdateResultCode[AppUpdateResultCode["OK"] = 0] = "OK";
    /**
     * The user canceled the update.
     */
    AppUpdateResultCode[AppUpdateResultCode["CANCELED"] = 1] = "CANCELED";
    /**
     * The update failed.
     */
    AppUpdateResultCode[AppUpdateResultCode["FAILED"] = 2] = "FAILED";
    /**
     * No update is available.
     */
    AppUpdateResultCode[AppUpdateResultCode["NOT_AVAILABLE"] = 3] = "NOT_AVAILABLE";
    /**
     * The requested update type is not allowed.
     * For example, trying to perform an immediate update when only flexible is allowed.
     */
    AppUpdateResultCode[AppUpdateResultCode["NOT_ALLOWED"] = 4] = "NOT_ALLOWED";
    /**
     * Required information is missing.
     * This can happen if {@link CapacitorUpdaterPlugin.getAppUpdateInfo} wasn't called first.
     */
    AppUpdateResultCode[AppUpdateResultCode["INFO_MISSING"] = 5] = "INFO_MISSING";
})(exports.AppUpdateResultCode || (exports.AppUpdateResultCode = {}));

/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */
const CapacitorUpdater = core.registerPlugin('CapacitorUpdater', {
    web: () => Promise.resolve().then(function () { return web; }).then((m) => new m.CapacitorUpdaterWeb()),
});

/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */
const BUNDLE_BUILTIN = {
    status: 'success',
    version: '',
    downloaded: '1970-01-01T00:00:00.000Z',
    id: 'builtin',
    checksum: '',
};
class CapacitorUpdaterWeb extends core.WebPlugin {
    async setStatsUrl(options) {
        console.warn('Cannot setStatsUrl in web', options);
        return;
    }
    async setUpdateUrl(options) {
        console.warn('Cannot setUpdateUrl in web', options);
        return;
    }
    async setChannelUrl(options) {
        console.warn('Cannot setChannelUrl in web', options);
        return;
    }
    async download(options) {
        console.warn('Cannot download version in web', options);
        return BUNDLE_BUILTIN;
    }
    async next(options) {
        console.warn('Cannot set next version in web', options);
        return BUNDLE_BUILTIN;
    }
    async isAutoUpdateEnabled() {
        console.warn('Cannot get isAutoUpdateEnabled in web');
        return { enabled: false };
    }
    async set(options) {
        console.warn('Cannot set active bundle in web', options);
        return;
    }
    async startPreviewSession(options) {
        console.warn('Cannot start preview session in web', options);
        return;
    }
    async listPreviews() {
        console.warn('Cannot list previews in web');
        return { previews: [], currentBundle: BUNDLE_BUILTIN };
    }
    async setPreview(options) {
        console.warn('Cannot set preview in web', options);
        return;
    }
    async resetPreview() {
        console.warn('Cannot reset preview in web');
        return;
    }
    async deletePreview(options) {
        console.warn('Cannot delete preview in web', options);
        return { removed: false, deleted: false };
    }
    async checkPreviewUpdate(options) {
        console.warn('Cannot check preview update in web', options);
        throw this.unimplemented('Preview updates are not available on web platform');
    }
    async updatePreview(options) {
        console.warn('Cannot update preview in web', options);
        throw this.unimplemented('Preview updates are not available on web platform');
    }
    async getDeviceId() {
        console.warn('Cannot get ID in web');
        return { deviceId: 'default' };
    }
    async getBuiltinVersion() {
        console.warn('Cannot get version in web');
        return { version: 'default' };
    }
    async getPluginVersion() {
        console.warn('Cannot get plugin version in web');
        return { version: 'default' };
    }
    async delete(options) {
        console.warn('Cannot delete bundle in web', options);
    }
    async setBundleError(options) {
        console.warn('Cannot setBundleError in web', options);
        return BUNDLE_BUILTIN;
    }
    async list() {
        console.warn('Cannot list bundles in web');
        return { bundles: [] };
    }
    async reset(options) {
        console.warn('Cannot reset version in web', options);
    }
    async current() {
        console.warn('Cannot get current bundle in web');
        return { bundle: BUNDLE_BUILTIN, native: '0.0.0' };
    }
    async reload() {
        console.warn('Cannot reload current bundle in web');
        return;
    }
    async getLatest() {
        console.warn('Cannot getLatest current bundle in web');
        return {
            version: '0.0.0',
            message: 'Cannot getLatest current bundle in web',
        };
    }
    async triggerUpdateCheck() {
        console.warn('Cannot triggerUpdateCheck in web');
        return { status: 'unavailable', queued: false };
    }
    async getMissingBundleFiles(options) {
        var _a, _b, _c;
        console.warn('Cannot inspect missing bundle files in web', { manifestLength: (_b = (_a = options.manifest) === null || _a === void 0 ? void 0 : _a.length) !== null && _b !== void 0 ? _b : 0 });
        const missing = (_c = options.manifest) !== null && _c !== void 0 ? _c : [];
        return {
            missing,
            total: missing.length,
            missingCount: missing.length,
            reusableCount: 0,
        };
    }
    async getBundleDownloadSize(options) {
        var _a, _b, _c, _d, _e;
        console.warn('Cannot estimate bundle download size in web', { manifestLength: (_b = (_a = options.manifest) === null || _a === void 0 ? void 0 : _a.length) !== null && _b !== void 0 ? _b : 0 });
        return {
            totalSize: 0,
            knownFiles: 0,
            unknownFiles: (_d = (_c = options.manifest) === null || _c === void 0 ? void 0 : _c.length) !== null && _d !== void 0 ? _d : 0,
            files: ((_e = options.manifest) !== null && _e !== void 0 ? _e : []).map((entry) => ({
                file_name: entry.file_name,
                file_hash: entry.file_hash,
                download_url: entry.download_url,
                error: 'unavailable',
            })),
        };
    }
    async setChannel(options) {
        console.warn('Cannot setChannel in web', options);
        return {
            status: 'error',
            error: 'Cannot setChannel in web',
        };
    }
    async unsetChannel(options) {
        console.warn('Cannot unsetChannel in web', options);
        return;
    }
    async setCustomId(options) {
        console.warn('Cannot setCustomId in web', options);
        return;
    }
    async getChannel() {
        console.warn('Cannot getChannel in web');
        return {
            status: 'error',
            error: 'Cannot getChannel in web',
        };
    }
    async listChannels() {
        console.warn('Cannot listChannels in web');
        throw {
            message: 'Cannot listChannels in web',
            error: 'platform_not_supported',
        };
    }
    async notifyAppReady() {
        return { bundle: BUNDLE_BUILTIN };
    }
    async setMultiDelay(options) {
        console.warn('Cannot setMultiDelay in web', options === null || options === void 0 ? void 0 : options.delayConditions);
        return;
    }
    async cancelDelay() {
        console.warn('Cannot cancelDelay in web');
        return;
    }
    async isAutoUpdateAvailable() {
        console.warn('Cannot isAutoUpdateAvailable in web');
        return { available: false };
    }
    async getCurrentBundle() {
        console.warn('Cannot get current bundle in web');
        return BUNDLE_BUILTIN;
    }
    async getNextBundle() {
        return Promise.resolve(null);
    }
    async getFailedUpdate() {
        console.warn('Cannot getFailedUpdate in web');
        return null;
    }
    async setShakeMenu(_options) {
        throw this.unimplemented('Shake menu not available on web platform');
    }
    async isShakeMenuEnabled() {
        return Promise.resolve({ enabled: false, gesture: 'shake' });
    }
    async setShakeChannelSelector(_options) {
        throw this.unimplemented('Shake channel selector not available on web platform');
    }
    async isShakeChannelSelectorEnabled() {
        return Promise.resolve({ enabled: false });
    }
    async getAppId() {
        console.warn('Cannot getAppId in web');
        return { appId: 'default' };
    }
    async setAppId(options) {
        console.warn('Cannot setAppId in web', options);
        return;
    }
    // ============================================================================
    // App Store / Play Store Update Methods (Web stubs)
    // ============================================================================
    async getAppUpdateInfo(_options) {
        console.warn('getAppUpdateInfo is not available on web platform');
        return {
            currentVersionName: '0.0.0',
            currentVersionCode: '0',
            updateAvailability: exports.AppUpdateAvailability.UNKNOWN,
        };
    }
    async openAppStore(_options) {
        throw this.unimplemented('openAppStore is not available on web platform');
    }
    async performImmediateUpdate() {
        throw this.unimplemented('performImmediateUpdate is only available on Android');
    }
    async startFlexibleUpdate() {
        throw this.unimplemented('startFlexibleUpdate is only available on Android');
    }
    async completeFlexibleUpdate() {
        throw this.unimplemented('completeFlexibleUpdate is only available on Android');
    }
}

var web = /*#__PURE__*/Object.freeze({
    __proto__: null,
    CapacitorUpdaterWeb: CapacitorUpdaterWeb
});

exports.CapacitorUpdater = CapacitorUpdater;
//# sourceMappingURL=plugin.cjs.js.map
