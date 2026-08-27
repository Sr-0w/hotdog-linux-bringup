# Markdown audit - 2026-08-25

This register lists every Git-tracked Markdown file after the Alpha 5
documentation audit. Current documents were checked against `README.md`,
`docs/status.md`, package revisions `r181`/`3-r32` and the published
Alpha 5 manifest. Dated evidence and release notes retain their original
observations; misleading intermediate conclusions carry supersession notes.

Automated checks also require UTF-8, non-empty content, a level-1 title
where the native format permits one, and a list exactly matching Git.
Local Markdown links are checked separately by `validate-public-tree.sh`.
An external-link pass returned HTTP 200 for 42 of 46 unique URLs; the
four exact lore.kernel.org message links returned the site's automated
client 403 response and were retained as immutable submission IDs.

Total: **219 Markdown files**.

| Role | Count |
|---|---:|
| Audit register | 1 |
| Current documentation | 30 |
| Disabled helper | 1 |
| Evidence | 169 |
| Evidence policy | 1 |
| Mail archive | 1 |
| Package documentation | 5 |
| Package history | 1 |
| Project history | 3 |
| Release record | 5 |
| Work note | 2 |

## File-by-file register

| File | Role | Review result |
|---|---|---|
| `.github/PULL_REQUEST_TEMPLATE.md` | Current documentation | Reviewed against Alpha 5 and current status |
| `CONTRIBUTING.md` | Current documentation | Reviewed against Alpha 5 and current status |
| `README.md` | Current documentation | Reviewed against Alpha 5 and current status |
| `SECURITY.md` | Current documentation | Reviewed against Alpha 5 and current status |
| `aports/README.md` | Package documentation | Reviewed against current package roles |
| `aports/device/testing/firmware-oneplus-hotdog-modem-oos10/README.md` | Package documentation | Reviewed against current package roles |
| `aports/device/testing/firmware-oneplus-hotdog-slpi/README.md` | Package documentation | Reviewed against current package roles |
| `aports/device/testing/linux-oneplus-hotdog-mainline616/README.md` | Package documentation | Reviewed against current package roles |
| `aports/device/testing/linux-oneplus-hotdog-mainline617-clean/README.md` | Package documentation | Reviewed against current package roles |
| `aports/device/testing/linux-oneplus-hotdog-mainline617-k1/README.md` | Package history | Historical K1 package scope stated |
| `docs/README.md` | Current documentation | Reviewed against Alpha 5 and current status |
| `docs/android-reference.md` | Current documentation | Reviewed against Alpha 5 and current status |
| `docs/artifact-retention.md` | Current documentation | Reviewed against Alpha 5 and current status |
| `docs/artifacts.md` | Current documentation | Reviewed against Alpha 5 and current status |
| `docs/boot-flow.md` | Current documentation | Reviewed against Alpha 5 and current status |
| `docs/bringup-history.md` | Project history | Historical scope/supersession stated |
| `docs/build-and-test.md` | Current documentation | Reviewed against Alpha 5 and current status |
| `docs/camera-port-plan.md` | Project history | Historical scope/supersession stated |
| `docs/device-safety.md` | Current documentation | Reviewed against Alpha 5 and current status |
| `docs/direct-boot.md` | Current documentation | Reviewed against Alpha 5 and current status |
| `docs/evidence/2026-07-11-mainline-k1.md` | Evidence | Historical evidence; explicit supersession note present |
| `docs/evidence/2026-07-12-direct-boot.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-07-12-packaging.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-07-15-k1-kexec-userspace.md` | Evidence | Historical evidence; explicit supersession note present |
| `docs/evidence/2026-07-15-raid6-direct-boot.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-07-30-direct-pid1.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-07-31-direct-native-ufs.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-01-r6-ufs-live-probe.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-03-direct-mainline-rootfs.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-03-direct-mainline-usb.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-03-mainline616-pmaports.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-03-native-display.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-04-mainline616-adsp-preflight.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-04-mainline616-battery-charger-preflight.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-04-mainline616-battery-charger.md` | Evidence | Historical evidence; explicit supersession note present |
| `docs/evidence/2026-08-04-mainline616-bluetooth.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-04-mainline616-display-90hz.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-04-mainline616-gpu.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-04-mainline616-graphical-userspace.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-04-mainline616-mpss-rmtfs-preflight.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-04-mainline616-smb5-parameters.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-04-mainline616-touchscreen.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-04-mainline616-volume-keys.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-04-mainline616-wcd9340-preflight.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-04-mainline616-wifi-mpss.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-05-mainline616-adsp.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-05-mainline616-audio-card.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-05-mainline616-dynamic-refresh.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-05-mainline616-flatpak-ufs.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-05-mainline616-headphone-backend.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-05-mainline616-internal-speakers.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-05-mainline616-public-image.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-05-mainline616-suspend-policy.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-05-mainline616-tfa9874-probe.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-05-mainline616-wcd9340.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-05-oxygenos-hardware-reference.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-07-mainline616-microphone.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-07-mainline616-remaining-hardware.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-07-mainline616-suspend.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-07-mainline616-usb-role.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-09-mainline616-camera-imx586.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-09-mainline616-camera-libcamera.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-09-mainline616-camera-power-sequence.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-09-mainline616-camera-telephoto-focus.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-09-mainline616-camera-telephoto.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-10-ab-slot-success.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-10-gnss-qmi-loc.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-10-mainline616-camera-autofocus.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-10-mainline616-camera-imx471-popup.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-10-mainline616-camera-imx481.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-10-mainline616-camera-imx586-focus.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-10-mainline616-software-reboot.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-10-nfc-nxp-nci.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-10-slpi-sensor-dsp.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-10-v0.1.0-alpha.1.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-11-haptics-aw8697.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-11-upstream-review-audit.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-12-camera-flash.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-12-ipa-v41-memory-map.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-12-ipa-v41-scope.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-12-upstream-follow-up.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-13-hexagonrpcd-write.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-13-single-battery-offline-fix.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-13-smb5-v3-hardware-validation.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-14-typec-input-current.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-15-smb5-tcpm-register-ownership.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-16-smb5-complete-900ma.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-17-ab-slot-retry-regression.md` | Evidence | Historical evidence; explicit supersession note present |
| `docs/evidence/2026-08-17-dsi-dsc-transport-errors.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-17-suspend-resume-defects.md` | Evidence | Historical evidence; explicit supersession note present |
| `docs/evidence/2026-08-18-ipa-ssr-notifier-deadlock.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-18-sdhc2-modem-power-domain.md` | Evidence | Historical evidence; explicit supersession note present |
| `docs/evidence/2026-08-19-adsp-crash-wedges-pm.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-19-ath10k-wakeup-capability.md` | Evidence | Historical evidence; explicit supersession note present |
| `docs/evidence/2026-08-19-boot-image-avb-footer.md` | Evidence | Historical evidence; explicit supersession note present |
| `docs/evidence/2026-08-19-fastrpc-nsessions.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-19-fingerprint-goodix-udfps.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-19-first-suspend-residual.md` | Evidence | Historical evidence; explicit supersession note present |
| `docs/evidence/2026-08-19-icb-arbiter-qup-client.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-19-icb-info-devcfg.md` | Evidence | Historical evidence; explicit supersession note present |
| `docs/evidence/2026-08-19-init-attach-sns-vs-adsprpc.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-19-npa-client-type-gate.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-19-pd-hard-reset-charge-gap.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-19-proxy-power-domains.md` | Evidence | Historical evidence; explicit supersession note present |
| `docs/evidence/2026-08-19-sensor-config-set-is-from-the-wrong-oxygenos.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-19-sensor-core-registers-no-driver.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-19-sensors-handover.md` | Evidence | Historical evidence; explicit supersession note present |
| `docs/evidence/2026-08-19-sensors-pd-address-space.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-19-which-sensors-this-board-actually-has.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-20-alsps-registry-request-set.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-20-curated-sensor-config-and-sar-events.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-20-display-regression-01.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-20-see-driver-api-table.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-20-sensor-pd-clock-and-island-control.md` | Evidence | Historical evidence; explicit supersession note present |
| `docs/evidence/2026-08-20-smb5-v4-dock-validation.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-20-tcs3701-only-slpi-coredump.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-20-the-port-open-allocates-from-island-memory.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-20-true-sensor-config-set-is-not-enough.md` | Evidence | Historical evidence; explicit supersession note present |
| `docs/evidence/2026-08-20-where-the-sensor-driver-code-lives.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-21-alsps-driver-messages-and-a-method-correction.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-21-coresight-trace-not-authorised.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-21-one-hardware-sensor-does-register.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-21-pm8150-pon-reboot-modes.md` | Evidence | Historical evidence; explicit supersession note present |
| `docs/evidence/2026-08-21-qdssc-etm-reachable-without-flash.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-21-two-service-registry-locators.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-23-a-device-answers-at-0x30.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-23-als-type-provenance-and-eliminations.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-23-continuous-sensors-stream.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-23-everything-waits-on-the-accelerometer.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-23-fastrpc-invoke-print-floods-the-log.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-23-linux-holds-the-sar-interrupt-pin.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-23-one-sensor-streams-and-what-that-rules-out.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-23-only-bus-instance-3-works.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-23-proximity-reaches-its-chip.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-23-sar-reaches-its-chip-proximity-does-not.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-23-the-firmware-version-was-the-cause.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-23-the-gates-in-the-drivers.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-23-the-island-region-is-opaque-to-address-search.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-23-the-magnetometer-is-not-at-0x0c.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-23-the-oppo-project-id-is-zero.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-23-the-proximity-driver-runs-and-writes-back-zero.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-23-the-sensor-descriptor-table.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-23-the-spi-bus-never-initialises.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-23-the-stock-registry-verbatim-changes-nothing.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-23-the-working-firmware-uses-a-different-driver-set.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-23-two-sensors-are-at-the-wrong-address.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-23-userspace-has-a-sensor-path-now.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-23-userspace-has-no-sensor-path-yet.md` | Evidence | Historical evidence; explicit supersession note present |
| `docs/evidence/2026-08-23-which-drivers-this-firmware-actually-contains.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-24-alert-slider.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-24-dual-sim-slot2-pin.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-24-elliptic-ultrasonic-proximity-port.md` | Evidence | Historical evidence; explicit supersession note present |
| `docs/evidence/2026-08-24-my-decoder-was-hiding-four-sensors.md` | Evidence | Historical evidence; explicit supersession note present |
| `docs/evidence/2026-08-24-oxygenos-modem-stack-architecture.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-24-proximity-alone.md` | Evidence | Historical evidence; explicit supersession note present |
| `docs/evidence/2026-08-24-proximity-is-ultrasonic.md` | Evidence | Historical evidence; explicit supersession note present |
| `docs/evidence/2026-08-24-proximity-may-not-be-a-see-sensor.md` | Evidence | Historical evidence; explicit supersession note present |
| `docs/evidence/2026-08-24-quick-wins-runtime.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-24-the-oxygenos-vendor-is-recoverable.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-24-where-proximity-is-decided.md` | Evidence | Historical evidence; explicit supersession note present |
| `docs/evidence/2026-08-25-elliptic-protocol-from-oxygenos.md` | Evidence | Historical evidence; explicit supersession note present |
| `docs/evidence/2026-08-25-modemmanager-preonline-gate.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-25-oxygenos-mcfg-catalog.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-25-oxygenos-modem-firmware-bundle.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-25-package-complete-runtime.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-25-proximity-reports-near-and-far.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-25-radio-dms-shutdown-gate.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-25-radio-mcfg-dry-plan.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-25-radio-nas-preonline.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-25-radio-pdc-apply-nosim.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-25-radio-pdc-readonly.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-25-radio-pdc-resident-catalog.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-25-radio-pin-reattest.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-25-radio-uim-slot-identity.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-25-radio-wds-profile-probe.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-25-ufs-ice-reboot-mode.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-25-v0.1.0-alpha.2.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-25-v0.1.0-alpha.3.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-26-bluetooth-two-bugs-behind-one-dead-controller.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-26-imu-orientation-is-the-transpose-of-the-registry.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-26-sm8150-6.17-complete-runtime.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-26-sm8150-6.17-radio-audio.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-26-sm8150-6.17-userdata-gpt-dwc3.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-27-displayport-alt-mode-was-dropped-in-the-migration.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-27-slpi-watchdog-every-40-seconds.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-27-the-adsp-does-implement-hdmi-over-dp.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/2026-08-27-two-drivers-one-compatible-silenced-the-speakers.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/README.md` | Evidence policy | Current archive/supersession policy |
| `docs/evidence/k1-dtb-source.md` | Evidence | Historical evidence; dated observations preserved |
| `docs/evidence/k1-kernel-package.md` | Evidence | Historical evidence; explicit supersession note present |
| `docs/factory-calibration.md` | Current documentation | Reviewed against Alpha 5 and current status |
| `docs/hardware-roadmap.md` | Current documentation | Reviewed against Alpha 5 and current status |
| `docs/host-setup.md` | Current documentation | Reviewed against Alpha 5 and current status |
| `docs/kernel-migration-sm8150-6.17.md` | Current documentation | Reviewed against Alpha 5 and current status |
| `docs/mainline-bringup.md` | Project history | Historical scope/supersession stated |
| `docs/markdown-audit-2026-08-25.md` | Audit register | Generated and checked by this audit tool |
| `docs/pmaports-upstreaming.md` | Current documentation | Reviewed against Alpha 5 and current status |
| `docs/postmarketos-wiki-page-mockup.md` | Current documentation | Reviewed against Alpha 5 and current status |
| `docs/qdssc-client.md` | Current documentation | Reviewed against Alpha 5 and current status |
| `docs/reference/see-message-ids.md` | Current documentation | Reviewed against Alpha 5 and current status |
| `docs/release-install.md` | Current documentation | Reviewed against Alpha 5 and current status |
| `docs/release-notes-v0.1.0-alpha.1.md` | Release record | Immutable description of its exact release |
| `docs/release-notes-v0.1.0-alpha.2.md` | Release record | Immutable description of its exact release |
| `docs/release-notes-v0.1.0-alpha.3.md` | Release record | Immutable description of its exact release |
| `docs/release-notes-v0.1.0-alpha.4.md` | Release record | Immutable description of its exact release |
| `docs/release-notes-v0.1.0-alpha.5.md` | Release record | Immutable description of its exact release |
| `docs/repository-layout.md` | Current documentation | Reviewed against Alpha 5 and current status |
| `docs/roadmap.md` | Current documentation | Reviewed against Alpha 5 and current status |
| `docs/sensors-slpi-ap-stm-etf-decode.md` | Current documentation | Reviewed against Alpha 5 and current status |
| `docs/sensors-slpi-coresight-ap-smoke.md` | Current documentation | Reviewed against Alpha 5 and current status |
| `docs/sensors-slpi-repro-v1.md` | Current documentation | Reviewed against Alpha 5 and current status |
| `docs/sources.md` | Current documentation | Reviewed against Alpha 5 and current status |
| `docs/status.md` | Current documentation | Reviewed against Alpha 5 and current status |
| `docs/upstream-submissions.md` | Current documentation | Reviewed against Alpha 5 and current status |
| `helpers/r6-ufs-regdump/README.md` | Disabled helper | Fail-closed safety status verified |
| `kernel-checkpoints/clearstaff-403b56c-r181/README.md` | Current documentation | Reviewed against Alpha 5 and current status |
| `upstream/2026-08-12/README.md` | Mail archive | Immutable upstream submission context |
| `work/ipa-v4.1/README.md` | Work note | Historical/experimental scope stated |
| `work/scc-sm8150/README.md` | Work note | Historical/experimental scope stated |
