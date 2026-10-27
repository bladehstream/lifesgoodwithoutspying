"""Exercise worker lifecycle with real processes and isolated fake executable mounts."""
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

ROOT=Path(__file__).resolve().parents[1]

class Worker(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base=Path(self.tmp.name)
        self.init=self.base/'init'; self.init.mkdir()
        self.state=self.base/'state';self.state.mkdir()
        lib=(ROOT/'app/init/nospy-lib.sh').read_text().replace('/var/lib/webosbrew',str(self.state)).replace('/tmp/lifesgoodwithoutspying',str(self.base/'runtime'))
        # Only mount/process operations are faked; locking, token/PID ownership,
        # real worker execution, cancellation and file publication are exercised.
        lib+='''
ads_execs() { [ ! -f "$DIR/../late" ] || echo "$DIR/../late"; }
voice_execs() { :; }; thinq_execs() { :; }
existing_targets() { cat; }
stub_owned() { [ -f "$1.blocked" ]; }
stub_mount() { [ ! -f "$DIR/../reject" ] || return 1; touch "$2.blocked"; }
kill_by_paths() { :; }
count_running_paths() { echo 0; }
'''
        (self.init/'nospy-lib.sh').write_text(lib)
        (self.init/'nospy-watch.sh').write_text((ROOT/'app/init/nospy-watch.sh').read_text().replace('sleep 15 &','sleep 0.05 &').replace('/tmp/lifesgoodwithoutspying.watch.',str(self.base/'work.')))
        (self.state/'lifesgoodwithoutspying.conf').write_text('ads.stop=on\nvoice.stop=off\ndomains.thinq=off\n')
        self.shell=subprocess.Popen(['sh'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env=dict(os.environ))
        self.send(f'DIR={self.init}; . "$DIR/nospy-lib.sh"; watch_start; echo READY')
        self.assertEqual(self.shell.stdout.readline().strip(),'READY')
        self.addCleanup(self.close)

    def send(self,s):
        self.shell.stdin.write(s+'\n');self.shell.stdin.flush()

    def close(self):
        if self.shell.poll() is None:
            self.send('watch_stop; exit')
            self.shell.communicate(timeout=3)

    def until(self,predicate):
        end=time.monotonic()+3
        while time.monotonic()<end:
            if predicate(): return
            time.sleep(.02)
        self.fail('worker did not reach expected state')

    def test_late_target_and_restore_cancellation(self):
        late=self.base/'late';late.touch()
        self.until(lambda: (self.base/'late.blocked').exists())
        self.send('watch_status; watch_stop; echo STOPPED')
        self.assertEqual(self.shell.stdout.readline().strip(),'running')
        self.assertEqual(self.shell.stdout.readline().strip(),'STOPPED')
        (self.base/'late.blocked').unlink()
        time.sleep(.2)
        self.assertFalse((self.base/'late.blocked').exists())
        self.assertFalse((self.base/'runtime.watch').exists())
        self.assertFalse((self.base/'runtime.lock').exists())

    def test_replacement_generation_survives_old_worker_cleanup(self):
        before=(self.base/'runtime.watch').read_text().split()[1]
        self.send('watch_start; echo REPLACED')
        self.assertEqual(self.shell.stdout.readline().strip(),'REPLACED')
        self.assertNotEqual(before,(self.base/'runtime.watch').read_text().split()[1])
        time.sleep(.15)
        self.send('watch_status')
        self.assertEqual(self.shell.stdout.readline().strip(),'running')
        (self.base/'late').touch()
        self.until(lambda: (self.base/'late.blocked').exists())

    def test_failed_mount_is_visible_and_worker_stops(self):
        (self.base/'reject').touch();(self.base/'late').touch()
        self.until(lambda: (self.base/'runtime.watch-error').exists())
        self.send('watch_status')
        self.assertEqual(self.shell.stdout.readline().strip(),'failed')
        self.assertFalse((self.base/'late.blocked').exists())

    def test_busy_lock_does_not_queue_stale_work(self):
        self.send('lock_acquire; echo LOCKED')
        self.assertEqual(self.shell.stdout.readline().strip(),'LOCKED')
        (self.base/'late').touch();time.sleep(.2)
        self.assertFalse((self.base/'late.blocked').exists())
        self.send('watch_stop; lock_release; echo STOPPED')
        self.assertEqual(self.shell.stdout.readline().strip(),'STOPPED')
        time.sleep(.1)
        self.assertFalse((self.base/'late.blocked').exists())

if __name__=='__main__':unittest.main(verbosity=2)
