#!/usr/bin/env python3
"""Check update authorization on a disposable Keychain item, never Claude's item."""
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import uuid

SOURCE = r'''
import Foundation
import Security
let version = "BUILD_VERSION"
SecKeychainSetUserInteractionAllowed(false)
let operation = CommandLine.arguments[1]
let service = CommandLine.arguments[2]
var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: service, kSecAttrAccount as String: "update-test"]
let status: OSStatus
if operation == "create" {
    query[kSecValueData as String] = Data("synthetic-update-check".utf8)
    status = SecItemAdd(query as CFDictionary, nil)
} else if operation == "delete" {
    status = SecItemDelete(query as CFDictionary)
} else {
    query[kSecReturnData as String] = true
    query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
    var result: CFTypeRef?
    status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecSuccess { precondition(result as? Data == Data("synthetic-update-check".utf8)) }
}
print("\(version) \(operation): \(status)")
exit(status == errSecSuccess ? 0 : 1)
'''


def main():
    certificate = Path(__file__).with_name("QuotaDisplay-Signing.cer")
    identity = hashlib.sha1(certificate.read_bytes()).hexdigest()
    with tempfile.TemporaryDirectory(prefix="quota-keychain-test-") as directory:
        root = Path(directory)
        for version, signer in [("A", identity), ("B", identity), ("C", "-")]:
            source = root / (version + ".swift")
            source.write_text(SOURCE.replace("BUILD_VERSION", version))
            subprocess.run(["xcrun", "swiftc", "-suppress-warnings", str(source), "-o", str(root / version)], check=True)
            subprocess.run(["codesign", "--force", "--timestamp=none", "--sign", signer,
                            "--identifier", "com.pducharme.QuotaDisplayMenu.SigningTest", str(root / version)], check=True)
        current = root / "Current"
        def install(version):
            shutil.copy2(root / version, root / "next")
            os.replace(root / "next", current)
        service = "com.pducharme.QuotaDisplayMenu.SigningTest." + str(uuid.uuid4())
        install("A")
        subprocess.run([str(current), "create", service], check=True)
        try:
            install("B")
            subprocess.run([str(current), "read", service], check=True)
            install("C")
            refused = subprocess.run([str(current), "read", service], capture_output=True, text=True)
            assert refused.returncode == 1 and any(str(code) in refused.stdout for code in [-25293, -25308]), refused.stdout
            print("Updated signed build accepted; unauthorized build refused without prompting.")
        finally:
            install("A")
            subprocess.run([str(current), "delete", service], check=True)


if __name__ == "__main__":
    main()
