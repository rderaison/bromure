#!/usr/bin/env python3
"""Regression cases for independent pointer evidence completeness."""
import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

CHECKER = Path(__file__).with_name('check-stress-x11-pointer.py')

class CheckerTests(unittest.TestCase):
    def fixture(self):
        rows=[]
        for vm in range(1,5):
            rows.append({'vm':vm,'kind':'x11-input','stream':'record','event':'ready','ordinal':1,
                         'root_width':100,'root_height':100,'geometry_ordinal':1,'sent_event':False})
            for i in range(6):
                rows.append({'vm':vm,'kind':'x11-input','stream':'record','event':'core_button',
                             'ordinal':i+2,'geometry_ordinal':1,'sent_event':False,'button':1,
                             'action':'down' if i%2==0 else 'up','root_width':100,'root_height':100,
                             'root_x':50,'root_y':50})
            rows.extend([{'vm':vm,'kind':'x11-input','event':'end','reason':'deadline'},
                         {'vm':vm,'kind':'x11-trace-exit','code':0}])
        return rows

    def run_checker(self, rows):
        lines=[]
        for vm in range(1,5):
            bridge=f'ObjectIdentifier(test{vm})'
            lines.extend([f'Test window id: {vm}', f'[GPU pointer] window={vm} bridge={bridge} buttons=1'])
            for i in range(6):
                packet=json.dumps({'x':.5,'y':.5,'buttons':1 if i%2==0 else 0})
                lines.append(f'[GPU pointer packet] bridge={bridge} t=1 json={packet}')
        # Deliberately put several observer records on the same host log line.
        lines.append(''.join('BROMURE_STRESS '+json.dumps(r) for r in rows))
        with tempfile.TemporaryDirectory() as directory:
            log=Path(directory)/'trace.log';log.write_text('\n'.join(lines))
            return subprocess.run([sys.executable,str(CHECKER),str(log)],capture_output=True,timeout=5).returncode

    def test_complete(self):
        self.assertEqual(self.run_checker(self.fixture()),0)

    def test_missing_geometry_reference(self):
        rows=self.fixture();rows[1]['geometry_ordinal']=9
        self.assertNotEqual(self.run_checker(rows),0)

    def test_dimensions_disagree(self):
        rows=self.fixture();rows[1]['root_width']=200
        self.assertNotEqual(self.run_checker(rows),0)

    def test_interrupted_capture(self):
        rows=self.fixture();rows[7]['reason']='stopped_or_limit'
        self.assertNotEqual(self.run_checker(rows),0)

    def test_explicit_error(self):
        rows=self.fixture();rows.append({'vm':1,'kind':'x11-input','event':'error','message':'lost stream'})
        self.assertNotEqual(self.run_checker(rows),0)

    def test_missing_release(self):
        rows=self.fixture();rows.pop(6)
        self.assertNotEqual(self.run_checker(rows),0)

if __name__ == '__main__':
    unittest.main()
