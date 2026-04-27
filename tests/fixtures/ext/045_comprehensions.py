# List, dict, set comprehensions and nested

# Basic list comprehension
squares = [x**2 for x in range(10)]
print(squares)                                        # [0, 1, 4, 9, 16, 25, 36, 49, 64, 81]

# With condition
evens = [x for x in range(20) if x % 2 == 0]
print(evens)                                          # [0, 2, 4, 6, 8, 10, 12, 14, 16, 18]

# Nested loops
pairs = [(x, y) for x in range(3) for y in range(3) if x != y]
print(len(pairs))                                     # 6

# Dict comprehension
word_len = {w: len(w) for w in ['hello', 'world', 'python']}
print(word_len['hello'])                              # 5
print(word_len['python'])                             # 6

# Invert a dict
orig = {'a': 1, 'b': 2, 'c': 3}
inv = {v: k for k, v in orig.items()}
print(inv[1])                                         # a
print(inv[3])                                         # c

# Set comprehension
unique_lens = {len(w) for w in ['hi', 'hello', 'hey', 'world']}
print(sorted(unique_lens))                            # [2, 3, 5]

# Conditional expression (ternary)
result = ['even' if x % 2 == 0 else 'odd' for x in range(6)]
print(result)                                         # ['even', 'odd', 'even', 'odd', 'even', 'odd']

# Nested list comprehension (flatten)
matrix = [[1, 2, 3], [4, 5, 6], [7, 8, 9]]
flat = [x for row in matrix for x in row]
print(flat)                                           # [1, 2, 3, 4, 5, 6, 7, 8, 9]

# Transpose
transposed = [[row[i] for row in matrix] for i in range(3)]
print(transposed[0])                                  # [1, 4, 7]
print(transposed[2])                                  # [3, 6, 9]

# Generator comprehension used with sum/any/all
gen_sum = sum(x**2 for x in range(5))
print(gen_sum)                                        # 30

has_neg = any(x < 0 for x in [1, 2, -3, 4])
print(has_neg)                                        # True

all_pos = all(x > 0 for x in [1, 2, 3, 4])
print(all_pos)                                        # True

print('done')
