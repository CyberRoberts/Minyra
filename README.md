# Minyra for Mac

Native AI Coding Agent for Intel macOS 12+ (source development preview).

This is a clean, source-only release under MIT. The official purple
cat-ear Mini mascot, artwork, Live2D models, private projects, personal
settings, build artifacts and original Git history are intentionally
not included. A new generic code-brackets icon is included for builds.

Build on a Mac with Xcode and Python 3 with Pillow installed:
  git clone https://github.com/CyberRoberts/Minyra.git
  cd Minyra
  python3 -m pip install Pillow==11.3.0
  bash Scripts/build_public.sh

Or open MinyraForMac.xcodeproj and choose the MinyraForMac scheme.
Tests simulate model responses; no DeepSeek key is included.
Live2D animation is omitted from this public snapshot; the app falls
back to the generic icon. The branded full build remains private.
The macOS app GUI has not completed Apple App Sandbox certification.
Real macOS 12 GUI and live DeepSeek QA remain separately required.

V1.0 is feature-frozen: no desktop/browser control, diff review or undo.
See LICENSE, ASSETS_LICENSE.md, CONTRIBUTING.md and SECURITY.md.

中文：Minyra for Mac（Mini 酱）程序代码采用 MIT 开源。
本仓库不包含紫色猫耳少女原画、角色分层或原始私有提交历史。
