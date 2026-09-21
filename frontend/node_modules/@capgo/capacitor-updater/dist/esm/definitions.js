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
export var AppUpdateAvailability;
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
})(AppUpdateAvailability || (AppUpdateAvailability = {}));
/**
 * Installation status for flexible updates (Android only).
 *
 * @since 8.0.0
 */
export var FlexibleUpdateInstallStatus;
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
})(FlexibleUpdateInstallStatus || (FlexibleUpdateInstallStatus = {}));
/**
 * Result codes for app update operations.
 *
 * @since 8.0.0
 */
export var AppUpdateResultCode;
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
})(AppUpdateResultCode || (AppUpdateResultCode = {}));
//# sourceMappingURL=definitions.js.map