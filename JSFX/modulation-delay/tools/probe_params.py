#!/usr/bin/env python3
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from render_harness import Harness
H = Harness("moddelay", "Magnolius/Magnolius_ModulationDelay.jsfx")
names, lines = H.probe_params()
for l in lines: print(l)
