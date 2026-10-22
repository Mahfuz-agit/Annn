import pathlib
import re
import sys

# This script runs after `flutter create` in GitHub Actions.
manifest = pathlib.Path("android/app/src/main/AndroidManifest.xml")
if not manifest.exists():
    sys.exit("AndroidManifest.xml not found. Run flutter create first.")

text = manifest.read_text(encoding="utf-8")
permissions = [
    ("android.permission.INTERNET", ""),
    ("android.permission.VIBRATE", ""),
    ("android.permission.READ_MEDIA_VIDEO", ""),
    ("android.permission.READ_MEDIA_VISUAL_USER_SELECTED", ""),
    ("android.permission.READ_EXTERNAL_STORAGE", ' android:maxSdkVersion="32"'),
]
block = ""
for name, extra in permissions:
    if name not in text:
        block += f'    <uses-permission android:name="{name}"{extra}/>\n'
text = re.sub(r"(<manifest[^>]*>\s*)", lambda m: m.group(1) + block, text, count=1)
text = re.sub(r'android:label="[^"]*"', 'android:label="Personal Feed"', text, count=1)
for attr in (
    'android:usesCleartextTraffic="true"',
    'android:requestLegacyExternalStorage="true"',
):
    key = attr.split("=")[0]
    if key not in text:
        text = text.replace("<application", "<application " + attr, 1)
manifest.write_text(text, encoding="utf-8")
print("Patched", manifest)

# permission_handler_android currently needs compile SDK 37 in the build log.
gradle_candidates = [
    pathlib.Path("android/app/build.gradle.kts"),
    pathlib.Path("android/app/build.gradle"),
]
gradle = next((p for p in gradle_candidates if p.exists()), None)
if gradle is None:
    sys.exit("android/app/build.gradle(.kts) not found")
gradle_text = gradle.read_text(encoding="utf-8")
gradle_text_new, n = re.subn(
    r"compileSdk\s*=\s*(?:flutter\.compileSdkVersion|\d+)",
    "compileSdk = 37",
    gradle_text,
    count=1,
)
if n == 0:
    gradle_text_new, n = re.subn(
        r"compileSdkVersion\s+(?:flutter\.compileSdkVersion|\d+)",
        "compileSdkVersion 37",
        gradle_text,
        count=1,
    )
if n == 0:
    sys.exit(f"Could not find compileSdk setting in {gradle}")
gradle.write_text(gradle_text_new, encoding="utf-8")
print("Set compile SDK 37 in", gradle)

# Add a native Android Storage Access Framework folder picker. It returns the
# selected shared-storage folder as a regular filesystem path (e.g. /storage/emulated/0/OSF).
kotlin_root = pathlib.Path("android/app/src/main/kotlin")
main_activity = next(iter(kotlin_root.rglob("MainActivity.kt")), None) if kotlin_root.exists() else None
if main_activity is None:
    sys.exit("MainActivity.kt not found under android/app/src/main/kotlin")
old_kotlin = main_activity.read_text(encoding="utf-8")
package_match = re.search(r"^\s*package\s+([A-Za-z0-9_.]+)", old_kotlin, re.MULTILINE)
if package_match is None:
    sys.exit(f"Could not find Kotlin package declaration in {main_activity}")
package_name = package_match.group(1)

kotlin = f'''package {package_name}

import android.app.Activity
import android.content.Intent
import android.os.Environment
import android.provider.DocumentsContract
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {{
    private val folderChannel = "personal_feed/folder_picker"
    private val folderRequestCode = 8821
    private var pendingFolderResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {{
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, folderChannel)
            .setMethodCallHandler {{ call, result ->
                if (call.method != "pickFolder") {{
                    result.notImplemented()
                }} else if (pendingFolderResult != null) {{
                    result.error("PICKER_BUSY", "A folder picker is already open.", null)
                }} else {{
                    pendingFolderResult = result
                    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {{
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                        addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
                        addFlags(Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
                    }}
                    try {{
                        startActivityForResult(intent, folderRequestCode)
                    }} catch (e: Exception) {{
                        pendingFolderResult = null
                        result.error("FOLDER_PICK_FAILED", e.message, null)
                    }}
                }}
            }}
    }}

    @Deprecated("Deprecated by Android; retained for the folder picker activity result")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {{
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != folderRequestCode) return

        val result = pendingFolderResult
        pendingFolderResult = null
        if (result == null) return

        if (resultCode != Activity.RESULT_OK || data?.data == null) {{
            result.success(null)
            return
        }}

        val treeUri = data.data!!
        val grantFlags = data.flags and
            (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        try {{
            contentResolver.takePersistableUriPermission(treeUri, grantFlags)
        }} catch (_: Exception) {{
            // The path and media permission can still work on devices that reject persistence.
        }}

        try {{
            val documentId = DocumentsContract.getTreeDocumentId(treeUri)
            val separator = documentId.indexOf(':')
            if (separator <= 0) {{
                result.error("UNSUPPORTED_FOLDER", "Could not resolve this folder to a storage path.", null)
                return
            }}
            val volume = documentId.substring(0, separator)
            val relative = documentId.substring(separator + 1).trim('/')
            val base = if (volume.equals("primary", ignoreCase = true)) {{
                Environment.getExternalStorageDirectory().absolutePath
            }} else {{
                "/storage/$volume"
            }}
            val path = if (relative.isEmpty()) base else "$base/$relative"
            result.success(path)
        }} catch (e: Exception) {{
            result.error("FOLDER_PICK_FAILED", e.message, null)
        }}
    }}
}}
'''
main_activity.write_text(kotlin, encoding="utf-8")
print("Patched native folder picker:", main_activity)
