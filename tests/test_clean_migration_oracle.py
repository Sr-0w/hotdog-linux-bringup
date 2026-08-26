import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
KERNEL_PACKAGE = (
    ROOT / "aports/device/testing/linux-oneplus-hotdog-mainline617-clean"
)
DEVICE_PACKAGE = ROOT / "aports/device/testing/device-oneplus-hotdog"
PMAPORTS_PATCH = (
    ROOT
    / "patches/pmaports/0001-initramfs-provision-optional-ACM-before-UDC-bind.patch"
)


class CleanMigrationOracleTests(unittest.TestCase):
    def test_r181_user_visible_config_contracts_are_retained(self):
        config = (
            KERNEL_PACKAGE
            / "config-oneplus-hotdog-mainline617-clean.aarch64"
        ).read_text()

        for expected in (
            "CONFIG_USB_GADGET_VBUS_DRAW=900",
            "CONFIG_V4L2_FLASH_LED_CLASS=m",
            "CONFIG_FONTS=y",
            "CONFIG_FONT_TER16x32=y",
        ):
            self.assertIn(expected, config)

    def test_acm_is_provisioned_before_the_initial_udc_bind(self):
        patch = PMAPORTS_PATCH.read_text()

        self.assertIn("deviceinfo_usb_acm", patch)
        self.assertIn("Add serial before the first UDC bind", patch)
        self.assertIn("debug_added_acm", patch)
        self.assertIn("pmb:support-openrc", patch)

    def test_rootfs_acm_service_does_not_reconfigure_configfs(self):
        service = (DEVICE_PACKAGE / "hotdog-usb-acm").read_text()

        self.assertIn("/dev/ttyGS0", service)
        for forbidden in ("usb_gadget", "/UDC", "ln -s", "mkdir"):
            self.assertNotIn(forbidden, service)

    def test_hotdog_requests_the_initial_acm_function(self):
        deviceinfo = (DEVICE_PACKAGE / "deviceinfo").read_text()

        self.assertIn('deviceinfo_usb_acm="true"', deviceinfo)

    def test_pmaports_preparer_pins_the_reviewed_base(self):
        preparer = (ROOT / "scripts/prepare-hotdog-pmaports-current.sh").read_text()

        self.assertIn("8d24be3f898eb8c717678ceb881972cc6b1c76f9", preparer)
        self.assertIn(PMAPORTS_PATCH.name, preparer)
        self.assertIn("--committer-date-is-author-date", preparer)


if __name__ == "__main__":
    unittest.main()
