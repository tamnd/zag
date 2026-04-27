import argparse

p = argparse.ArgumentParser(description='test')
p.add_argument('--foo', type=int, default=10)
p.add_argument('--bar', type=str, default='hello')

# defaults
args = p.parse_args([])
print(args.foo)
print(args.bar)

# override via argv
args2 = p.parse_args(['--foo', '42', '--bar', 'world'])
print(args2.foo)
print(args2.bar)

# Namespace constructor
ns = argparse.Namespace(x=1, y=2)
print(ns.x)
print(ns.y)
