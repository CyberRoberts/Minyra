from pathlib import Path
r=Path(__file__).resolve().parent.parent
assert len(list((r/'Sources').glob('*.swift')))>=15
assert len(list((r/'Assets/MiniAgent.iconset').glob('*.png')))==10
assert not (r/'CharacterLab').exists()
print('PUBLIC_SOURCE_PREFLIGHT_PASS')
