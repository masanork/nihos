#!/usr/bin/env python3
"""Replay software HID events into the RV32 interactive editor fixture."""
import hashlib
import json
from canvas_live import Guest, OUT
from console_reference import reference
from emulator_trace import source_identity


def expected(row):
    return reference('jetbrains', ['EDITOR DEMO', row, 'ASCII ONLY - HOST FILES'], control=False)


def main():
    source = source_identity()
    result = OUT / 'editor-smoke.json'
    result.unlink(missing_ok=True)
    guest = Guest()
    try:
        states = []
        initial = guest.start_editor()
        if initial['mode'] != 1 or initial['keys'] != 0 or initial['cursor'] != 0 or guest.raw != expected('|'):
            raise AssertionError('initial editor frame')
        states.append(initial.copy())
        # h, i, left, Shift+1, backspace, right; caret temporarily hides its cell.
        sequence = ((0, 0x0b, 'h|', 1, 1), (0, 0x0c, 'hi|', 2, 2),
                    (0, 0x50, 'h|', 2, 1), (2, 0x1e, 'h!|', 3, 2),
                    (0, 0x2a, 'h|', 4, 1), (0, 0x4f, 'hi|', 4, 2))
        for index, (modifiers, usage, row, edits, cursor) in enumerate(sequence, 1):
            state = guest.key(modifiers, usage)
            if state['mode'] != 1 or state['keys'] != index or state['edits'] != edits or state['cursor'] != cursor:
                raise AssertionError('editor state mismatch')
            if guest.raw != expected(row):
                raise AssertionError('editor frame differs from independent pixel reference')
            states.append(state.copy())
        if guest.state['text'] != 'hi':
            raise AssertionError('document contents differ from edits')
        loaded = guest.load_document('Saved text  ')
        if loaded['text'] != 'Saved text  ' or loaded['cursor'] != 12 or guest.raw != expected('Saved text  |'):
            raise AssertionError('document load and trailing spaces')
        if guest.load_document('')['text'] != '' or guest.raw != expected('|'):
            raise AssertionError('empty document load')
        try:
            guest.load_document('invalid\n')
        except ValueError:
            pass
        else:
            raise AssertionError('invalid document must be rejected')
        if guest.state['text'] != '':
            raise AssertionError('invalid load changed the document')
        guest.load_document('hi')
        before = guest.state['pixel_sha256']
        ignored = guest.key(2, 0x50)  # Shift-left does not silently become plain left.
        if ignored['cursor'] != 2 or ignored['edits'] != 4 or ignored['pixel_sha256'] != before:
            raise AssertionError('unsupported modified arrow changed editor')
        if source_identity() != source:
            raise RuntimeError('source changed during editor replay')
        receipt = {'evidence': 'esp-emu-rv32-interactive-editor-fixture', 'source': source,
                   'image_sha256': hashlib.sha256((OUT / 'nihos-native.bin').read_bytes()).hexdigest(),
                   'states': states, 'ignored': ignored,
                   'scope': 'software HID mailbox, bounded ASCII fixture and offscreen frame; no real keyboard, IME, panel or device timing'}
        result.write_text(json.dumps(receipt, indent=2) + '\n')
        print('RV32 interactive keyboard and independent editor frames passed:', result)
    finally:
        guest.close()


if __name__ == '__main__':
    main()
