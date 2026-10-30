"""Signup configuration must survive production config regeneration."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('pairdesk_config', ROOT / 'infra/production/configure.py')
config = importlib.util.module_from_spec(spec)
spec.loader.exec_module(config)


class SignupConfigTest(unittest.TestCase):
    def test_signup_policy_and_key_path_survive_render(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp)
            args = ('api.example.com', 'media.example.com', 'turn.example.com', '8.8.8.8', 'admin@example.com', output)
            config.render(*args)
            env = output / '.env'
            with env.open('a') as f:
                f.write('PAIRDESK_SIGNUP_ALLOWED_DOMAINS=futurepath.ai\n')
                f.write('PAIRDESK_ACCESS_ALLOWED_DOMAINS=futurepath.ai\n')
                f.write('PAIRDESK_ACCESS_ALLOWED_EMAILS=akshatsahu1@gmail.com\n')
                f.write('PAIRDESK_SIGNUP_VERIFY_EMAIL=true\n')
                f.write('PAIRDESK_RESEND_FROM=noreply@futurepath.ai\n')
                f.write('PAIRDESK_RESEND_API_KEY_HOST_FILE=/var/lib/pairdesk/resend-key\n')
            config.render(*args)
            text = env.read_text()
            self.assertIn('PAIRDESK_ACCESS_ALLOWED_EMAILS=akshatsahu1@gmail.com\n', text)
            self.assertIn('PAIRDESK_SIGNUP_VERIFY_EMAIL=true\n', text)
            self.assertIn('PAIRDESK_RESEND_API_KEY_HOST_FILE=/var/lib/pairdesk/resend-key\n', text)
            with env.open('a') as f:
                f.write('PAIRDESK_RESEND_FROM=$(unsafe)\n')
            with self.assertRaises(ValueError):
                config.render(*args)


if __name__ == '__main__':
    unittest.main()
