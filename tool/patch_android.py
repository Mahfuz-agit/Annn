import pathlib
import re
import sys

path = pathlib.Path("android/app/src/main/AndroidManifest.xml")
if not path.exists():
    sys.exit("AndroidManifest.xml not found. Run flutter create first.")

s = path.read_text(encoding="utf-8")

PERMS = [
    ("android.permission.INTERNET", ""),
    ("android.permission.VIBRATE", ""),
    ("android.permission.READ_MEDIA_VIDEO", ""),
    ("android.permission.READ_EXTERNAL_STORAGE", ' android:maxSdkVersion="32"'),
]

block = ""
for name, extra in PERMS:
    if name not in s:
        block += '    <uses-permission android:name="%s"%s/>\n' % (name, extra)

s = re.sub(r"(<manifest[^>]*>\s*)", lambda m: m.group(1) + block, s, count=1)
s = re.sub(r'android:label="[^"]*"', 'android:label="Personal Feed"', s, count=1)

for attr in (
    'android:usesCleartextTraffic="true"',
    'android:requestLegacyExternalStorage="true"',
):
    key = attr.split("=")[0]
    if key not in s:
        s = s.replace("<application", "<application " + attr, 1)

path.write_text(s, encoding="utf-8")
print("Patched", path)
