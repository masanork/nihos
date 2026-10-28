import unittest
from card_sim.normal import NormalSimulator
from card_sim.normal_scenarios import CASES


class NormalSimulatorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sim = NormalSimulator()


def scenario_test(case):
    def test(self):
        case(self.sim)
    return test


for name, case in CASES.items():
    setattr(NormalSimulatorTests, 'test_' + name.replace('-', '_'), scenario_test(case))
