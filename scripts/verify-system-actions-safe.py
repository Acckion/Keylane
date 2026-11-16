#!/usr/bin/env python3
"""Compile production AppleScripts and test audio logic with fake CoreAudio only.
--read-audio additionally queries the default output; it never writes audio properties.
No application launch, clipboard, permission prompt, keyboard or AX event is used.
"""
import argparse
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--read-audio', action='store_true')
args = parser.parse_args()
source = (root / 'Sources/Keylane/SystemActions.swift').read_text()
automation = source.split('    enum AutomationAction {', 1)[1].split('\n    static func runAutomation', 1)[0]
audio = 'enum SystemOutputMute {' + source.split('enum SystemOutputMute {', 1)[1]
mock_audio = audio
for name in ['AudioObjectGetPropertyData', 'AudioObjectSetPropertyData', 'AudioObjectHasProperty', 'AudioObjectIsPropertySettable']:
    mock_audio = mock_audio.replace(name, 'fake' + name)
prelude = '''
import AppKit
import AudioToolbox
import CoreAudio
var writes = 0
var deviceAvailable = true
var supported = true
var readFails = false
var writeFails = false
var scalar: Float32 = 0.426
var mute: UInt32 = 0
func fakeAudioObjectHasProperty(_ id: AudioObjectID, _ address: UnsafePointer<AudioObjectPropertyAddress>) -> Bool { supported }
func fakeAudioObjectIsPropertySettable(_ id: AudioObjectID, _ address: UnsafePointer<AudioObjectPropertyAddress>, _ writable: UnsafeMutablePointer<DarwinBoolean>) -> OSStatus {
    writable.pointee = DarwinBoolean(supported); return noErr
}
func fakeAudioObjectGetPropertyData(_ id: AudioObjectID, _ address: UnsafePointer<AudioObjectPropertyAddress>, _ count: UInt32, _ qualifier: UnsafeRawPointer?, _ size: UnsafeMutablePointer<UInt32>, _ data: UnsafeMutableRawPointer) -> OSStatus {
    if readFails { return -1 }
    switch address.pointee.mSelector {
    case kAudioHardwarePropertyDefaultOutputDevice: data.storeBytes(of: AudioDeviceID(deviceAvailable ? 42 : kAudioObjectUnknown), as: AudioDeviceID.self)
    case kAudioDevicePropertyMute: data.storeBytes(of: mute, as: UInt32.self)
    default: data.storeBytes(of: scalar, as: Float32.self)
    }
    return noErr
}
func fakeAudioObjectSetPropertyData(_ id: AudioObjectID, _ address: UnsafePointer<AudioObjectPropertyAddress>, _ count: UInt32, _ qualifier: UnsafeRawPointer?, _ size: UInt32, _ data: UnsafeRawPointer) -> OSStatus {
    writes += 1
    if writeFails { return -1 }
    if address.pointee.mSelector == kAudioDevicePropertyMute { mute = data.load(as: UInt32.self) }
    else { scalar = data.load(as: Float32.self) }
    return noErr
}
'''
checks = '''
precondition(SystemOutputVolume.current() == 43)
precondition(writes == 0)
for invalid in [-1, 101, Int.min, Int.max] { precondition(!SystemOutputVolume.set(invalid)) }
precondition(writes == 0)
for percent in [0, 25, 50, 75, 100] {
    precondition(SystemOutputVolume.set(percent))
    precondition(SystemOutputVolume.current() == percent)
}
precondition(writes == 5)
precondition(SystemOutputMute.toggle() == .muted && mute == 1)
precondition(SystemOutputMute.toggle() == .unmuted && mute == 0)
writeFails = true
precondition(!SystemOutputVolume.set(50))
precondition(SystemOutputMute.toggle() == .failed)
writeFails = false
readFails = true
precondition(SystemOutputVolume.current() == nil)
precondition(SystemOutputMute.toggle() == .failed)
readFails = false
supported = false
let before = writes
precondition(SystemOutputVolume.current() == nil)
precondition(!SystemOutputVolume.set(50))
precondition(SystemOutputMute.toggle() == .unsupported)
precondition(writes == before)
supported = true
deviceAvailable = false
precondition(SystemOutputVolume.current() == nil)
precondition(!SystemOutputVolume.set(50))
precondition(SystemOutputMute.toggle() == .failed)
print("PASS: fake audio read/write, bounds, rounding, presets, mute, unsupported and failure branches")
'''
compile_checks = '''
for action in [AutomationAction.emptyTrash, .logOut, .restart, .shutDown, .appearance] {
    var error: NSDictionary?
    guard let script = NSAppleScript(source: action.script), script.compileAndReturnError(&error) else {
        print("AppleScript compile failed: \\(String(describing: error))")
        exit(1)
    }
    precondition((action.confirmation != nil) == (action != .appearance))
}
print("PASS: five production AppleScripts compiled, none executed; confirmation policy")
'''
with tempfile.TemporaryDirectory(prefix='keylane-system-safe-') as directory:
    directory = pathlib.Path(directory)
    def run(name, code):
        file = directory / (name + '.swift')
        file.write_text(code)
        binary = directory / name
        subprocess.run(['swiftc', '-module-cache-path', str(directory / 'modules'), str(file), '-o', str(binary)], check=True)
        subprocess.run([str(binary)], check=True)
    run('mock', prelude + mock_audio + checks)
    run('scripts', 'import AppKit\nenum AutomationAction {' + automation + compile_checks)
    if args.read_audio:
        # Keep only SystemOutputVolume, omit its setter entirely for the live query.
        readonly = 'enum SystemOutputVolume {' + source.split('enum SystemOutputVolume {', 1)[1].split('    static func set(', 1)[0] + '}\n'
        assert 'AudioObjectSetPropertyData' not in readonly
        run('read', 'import AppKit\nimport AudioToolbox\nimport CoreAudio\n' + readonly + '\nprint("READ ONLY defaultDevice=\\(String(describing: SystemOutputVolume.defaultDevice())) percent=\\(String(describing: SystemOutputVolume.current()))")\n')
