"""Check the diagnostic's port against the checked-in C6 candidate config.

This checks configuration consistency only, not the firmware on a device or
packet routing. Changes to the routing policy require a fresh physical test.
"""

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parent.parent
CONFIG = ROOT / 'ports/esp-hosted-c6-time-v3/sdkconfig.idf556'
PROBE = ROOT / 'src/net/hosted_split_udp_probe.zig'


def check_contract(config, source):
    entries = {}
    for key, value in re.findall(r'^(CONFIG_[A-Z0-9_]+)=(.*)$', config, re.M):
        if key in entries:
            raise ValueError(f'duplicate config key: {key}')
        entries[key] = value
    for key in ('CONFIG_ESP_HOSTED_CP_FEAT_NW_SPLIT',
                'CONFIG_ESP_HOSTED_DEFAULT_NETWORK_STACK_COPROCESSOR',
                'CONFIG_ESP_HOSTED_HOST_ONLY_PORTS_CONFIGURED'):
        if entries.get(key) != 'y':
            raise ValueError(f'{key} must be enabled')
    for key in ('CONFIG_ESP_HOSTED_HOST_UDP_SRC_PORTS',
                'CONFIG_ESP_HOSTED_HOST_UDP_DST_PORTS'):
        if entries.get(key) != '""':
            raise ValueError(f'{key} changes the assumed routing policy')
    try:
        lo = int(entries['CONFIG_LWIP_UDP_REMOTE_PORT_RANGE_START'])
        hi = int(entries['CONFIG_LWIP_UDP_REMOTE_PORT_RANGE_END'])
        local_lo = int(entries['CONFIG_LWIP_UDP_LOCAL_PORT_RANGE_START'])
        local_hi = int(entries['CONFIG_LWIP_UDP_LOCAL_PORT_RANGE_END'])
    except (KeyError, ValueError) as exc:
        raise ValueError('missing or invalid UDP range') from exc
    if not (1 <= lo <= hi <= 65535 and 1 <= local_lo <= local_hi <= 65535):
        raise ValueError('invalid UDP range')
    if max(lo, local_lo) <= min(hi, local_hi):
        raise ValueError('host and coprocessor UDP ranges overlap')
    matches = re.findall(r'^pub const local_port: u16 = (\d+);$', source, re.M)
    if len(matches) != 1 or not lo <= int(matches[0]) <= hi:
        raise ValueError('diagnostic UDP port is outside host range')
    return lo, hi, int(matches[0])


class HostedSplitPortContract(unittest.TestCase):
    def setUp(self):
        self.config = CONFIG.read_text()
        self.source = PROBE.read_text()

    def test_checked_in_candidate(self):
        lo, hi, port = check_contract(self.config, self.source)
        self.assertLessEqual(lo, port)
        self.assertLessEqual(port, hi)

    def test_rejects_outside_port_and_overlapping_ranges(self):
        with self.assertRaises(ValueError):
            check_contract(self.config, self.source.replace('u16 = 49152;', 'u16 = 44444;'))
        with self.assertRaises(ValueError):
            check_contract(self.config.replace('UDP_LOCAL_PORT_RANGE_START=61440',
                                               'UDP_LOCAL_PORT_RANGE_START=61439'), self.source)

    def test_rejects_missing_split_and_explicit_udp_rules(self):
        with self.assertRaises(ValueError):
            check_contract(self.config.replace('CONFIG_ESP_HOSTED_CP_FEAT_NW_SPLIT=y',
                                               'CONFIG_ESP_HOSTED_CP_FEAT_NW_SPLIT=n'), self.source)
        with self.assertRaises(ValueError):
            check_contract(self.config.replace('CONFIG_ESP_HOSTED_HOST_UDP_DST_PORTS=""',
                                               'CONFIG_ESP_HOSTED_HOST_UDP_DST_PORTS="44444"'), self.source)

    def test_rejects_duplicate_config(self):
        with self.assertRaises(ValueError):
            check_contract(self.config + '\nCONFIG_LWIP_UDP_REMOTE_PORT_RANGE_START=1\n', self.source)


if __name__ == '__main__':
    unittest.main()
