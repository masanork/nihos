"""Host simulator regression gate: real builders, modeled register boundary."""
import unittest
from card_sim.backend import Simulator
from card_sim.scenarios import CASES


class CardSimulatorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sim = Simulator()


def scenario_test(case):
    def test(self):
        case(self.sim)
    return test


for name, case in CASES.items():
    setattr(CardSimulatorTests, 'test_' + name.replace('-', '_'), scenario_test(case))


if __name__ == '__main__':
    unittest.main()
