import argparse

# Basic parser
parser = argparse.ArgumentParser(description='Test parser')
parser.add_argument('--name', type=str, default='World')
parser.add_argument('--count', type=int, default=3)
parser.add_argument('--verbose', action='store_true')

args = parser.parse_args(['--name', 'Alice', '--count', '5'])
print(args.name)                                       # Alice
print(args.count)                                      # 5
print(args.verbose)                                    # False

args2 = parser.parse_args(['--verbose'])
print(args2.verbose)                                   # True
print(args2.name)                                      # World

# Positional args
parser2 = argparse.ArgumentParser()
parser2.add_argument('filename')
parser2.add_argument('--output', default='out.txt')

args3 = parser2.parse_args(['input.txt'])
print(args3.filename)                                  # input.txt
print(args3.output)                                    # out.txt

# Namespace access
ns = argparse.Namespace(x=1, y=2)
print(ns.x)                                            # 1
print(ns.y)                                            # 2

print('done')
