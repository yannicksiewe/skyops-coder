import os, sys
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from secrets_guardrail import redact, redact_messages

def test_known_key_formats_are_redacted():
    t, f = redact("aws: AKIAIOSFODNN7EXAMPLE gh: ghp_abcdefghijklmnopqrstuvwxyz0123456789ABCD sk: sk-proj-abcdefghijklmnop1234 g: AIzaSyA-1234567890abcdefghijklmnopqrstu")
    assert "AKIA" not in t and "ghp_" not in t and "sk-proj" not in t and "AIza" not in t
    assert f == {"aws_access_key": 1, "github_token": 1, "openai_style_key": 1, "google_api_key": 1}

def test_password_assignments_and_urls():
    t, f = redact("db: postgres://app:S3cr3tPass@db:5432/x and password: hunter2!! and PASSWORD=${DB_PASSWORD}")
    assert "S3cr3tPass" not in t and "hunter2" not in t and "${DB_PASSWORD}" in t   # env refs are fine
    assert f["url_credentials"] == 1 and f["password_assignment"] == 1

def test_private_key_and_jwt():
    t, f = redact("-----BEGIN RSA PRIVATE KEY-----\nMIIEow...\n-----END RSA PRIVATE KEY-----\njwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjMifQ.abcdefghijklmnop")
    assert "MIIEow" not in t and "eyJhbGci" not in t and f["private_key"] == 1 and f["jwt"] == 1

def test_placeholders_and_normal_code_untouched():
    src = 'api_key = os.environ["API_KEY"]\ntoken: <your-token>\ndef f(x):\n    return x * 2  # password strength check'
    t, f = redact(src)
    assert t == src and f == {}

def test_high_entropy_next_to_secret_word():
    t, f = redact("my secret is Zq8vT2mL9xK4pW7nR3sD6fG1hJ5kB0cV and the text key: hello_world_this_is_readable_text_ok")
    assert "Zq8vT2mL9xK4pW7nR3sD6fG1hJ5kB0cV" not in t and "hello_world" in t

def test_messages_with_parts():
    msgs = [{"role": "user", "content": [{"type": "text", "text": "token=ghp_abcdefghijklmnopqrstuvwxyz0123456789ABCD"}, {"type": "image_url", "image_url": {"url": "data:..."}}]},
            {"role": "user", "content": "plain: no secret here"}]
    out, f = redact_messages(msgs)
    assert "[REDACTED_GITHUB_TOKEN]" in out[0]["content"][0]["text"] and out[0]["content"][1]["type"] == "image_url"
    assert out[1]["content"] == "plain: no secret here" and f == {"github_token": 1}

def test_specific_type_wins_over_generic_assignment():
    t, f = redact("token=ghp_abcdefghijklmnopqrstuvwxyz0123456789ABCD")
    assert t == "token=[REDACTED_GITHUB_TOKEN]" and f == {"github_token": 1}
