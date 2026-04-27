import ast

# literal_eval -- safe eval of literal expressions
print(ast.literal_eval('42'))                          # 42
print(ast.literal_eval('"hello"'))                     # hello
print(ast.literal_eval('[1, 2, 3]'))                   # [1, 2, 3]
print(ast.literal_eval('{"a": 1}'))                    # {'a': 1}
print(ast.literal_eval('(True, None, False)'))         # (True, None, False)

# literal_eval rejects non-literals
try:
    ast.literal_eval('__import__("os")')
except (ValueError, TypeError):
    print('rejected')                                  # rejected

# parse -- returns a Module node
tree = ast.parse('x = 1 + 2')
print(type(tree).__name__)                             # Module
print(isinstance(tree, ast.Module))                    # True

# walk -- iterate all nodes
src = 'a = 1\nb = a + 2\n'
tree2 = ast.parse(src)
nodes = list(ast.walk(tree2))
print(len(nodes) > 0)                                  # True

# count specific node types
num_assigns = sum(1 for n in ast.walk(tree2) if isinstance(n, ast.Assign))
print(num_assigns)                                     # 2

num_names = sum(1 for n in ast.walk(tree2) if isinstance(n, ast.Name))
print(num_names)                                       # 3

# get_docstring
tree3 = ast.parse('def f():\n    """doc"""\n    pass\n')
fn = tree3.body[0]
print(ast.get_docstring(fn))                           # doc

print('done')
