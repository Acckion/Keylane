"""Safe source contracts; never imports or launches the application."""
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
MODULE = (ROOT / 'Sources/Keylane/SystemActionsModule.swift').read_text()
ACTIONS = (ROOT / 'Sources/Keylane/SystemActions.swift').read_text()


class SystemActionContracts(unittest.TestCase):
    def test_stable_ids_and_bilingual_keywords(self):
        rows = re.findall(r'command\("([^"\\]+)", "([^"]+)", "([^"]+)"', MODULE)
        self.assertEqual(len(rows), 32)
        self.assertEqual(len({r[0] for r in rows}), 32)
        self.assertTrue({'color', 'speak', 'stop-speaking', 'finder'} <= {r[0] for r in rows})
        for _, zh, en in rows:
            self.assertRegex(zh, r'[\u4e00-\u9fff]')
            self.assertRegex(en, r'[A-Za-z]')
        self.assertIn('keywords: [zh, en] + aliases', MODULE)
        self.assertIn('[0, 25, 50, 75, 100].map', MODULE)

    def test_permissions(self):
        expected = {'empty-trash': 'model.finderAutomation', 'log-out': 'events',
                    'restart-mac': 'events', 'shut-down': 'events',
                    'toggle-system-appearance': 'events', 'lock-screen': 'model.lockScreenPermission',
                    'dismiss-notifications': 'controls', 'toggle-bluetooth': 'controls',
                    'toggle-stage-manager': 'controls', 'play-pause': 'keyboard',
                    'next-track': 'keyboard', 'previous-track': 'keyboard',
                    'show-desktop': 'keyboard', 'toggle-hidden-files': 'keyboard',
                    'volume-up': 'keyboard', 'volume-down': 'keyboard', 'speak': 'model.clipboardSpeech'}
        for identifier, permission in expected.items():
            declaration = MODULE.split(f'command("{identifier}",', 1)[1].split(') {', 1)[0]
            self.assertIn('permission: ' + permission, declaration, identifier)

    def test_cancel_precedes_system_execution(self):
        automation = ACTIONS.split('static func runAutomation', 1)[1].split('static func openTrash', 1)[0]
        self.assertLess(automation.index('guard alert.runModal() == .alertSecondButtonReturn else { return }'),
                        automation.index('script.executeAndReturnError'))
        self.assertIn('case .emptyTrash:', ACTIONS)
        self.assertIn('case .logOut, .restart, .shutDown:', ACTIONS)
        quit_apps = ACTIONS.split('static func quitApplications', 1)[1].split('private static func awaitApplicationExit', 1)[0]
        self.assertLess(quit_apps.index('guard alert.runModal()'), quit_apps.index('application.terminate()'))

    def test_volume_form_defers_write_until_submit(self):
        view = MODULE.split('private struct SystemVolumeView', 1)[1]
        self.assertNotIn('setOutputVolume', view)
        self.assertIn('model?.pageID = .root', MODULE)
        self.assertIn('primaryEnabled: { volume.available }', MODULE)
        self.assertIn('guard let model, SystemActions.setOutputVolume(volume.percent) else { return }', MODULE)


if __name__ == '__main__':
    unittest.main()
