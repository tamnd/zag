# itertools combinations and permutations

import itertools

# combinations
c = list(itertools.combinations([1, 2, 3, 4], 2))
print(c)
# [(1, 2), (1, 3), (1, 4), (2, 3), (2, 4), (3, 4)]

c2 = list(itertools.combinations('ABC', 2))
print(c2)
# [('A', 'B'), ('A', 'C'), ('B', 'C')]

# combinations_with_replacement
cr = list(itertools.combinations_with_replacement([1, 2, 3], 2))
print(cr)
# [(1, 1), (1, 2), (1, 3), (2, 2), (2, 3), (3, 3)]

# permutations
p = list(itertools.permutations([1, 2, 3]))
print(len(p))                                       # 6
print(p[0])                                         # (1, 2, 3)
print(p[-1])                                        # (3, 2, 1)

p2 = list(itertools.permutations([1, 2, 3], 2))
print(len(p2))                                      # 6
print(p2)
# [(1, 2), (1, 3), (2, 1), (2, 3), (3, 1), (3, 2)]

# product
prod = list(itertools.product([1, 2], ['a', 'b']))
print(prod)
# [(1, 'a'), (1, 'b'), (2, 'a'), (2, 'b')]

prod2 = list(itertools.product(range(2), repeat=3))
print(len(prod2))                                   # 8
print(prod2[0])                                     # (0, 0, 0)
print(prod2[-1])                                    # (1, 1, 1)

# chain
chained = list(itertools.chain([1, 2], [3, 4], [5]))
print(chained)                                      # [1, 2, 3, 4, 5]

# chain.from_iterable
nested = [[1, 2], [3, 4], [5]]
flat = list(itertools.chain.from_iterable(nested))
print(flat)                                         # [1, 2, 3, 4, 5]

# islice
s = list(itertools.islice(range(100), 5, 15, 2))
print(s)                                            # [5, 7, 9, 11, 13]

# takewhile / dropwhile
tw = list(itertools.takewhile(lambda x: x < 5, [1, 2, 3, 4, 5, 6]))
print(tw)                                           # [1, 2, 3, 4]

dw = list(itertools.dropwhile(lambda x: x < 5, [1, 2, 3, 4, 5, 6]))
print(dw)                                           # [5, 6]

# groupby
data = sorted([('a', 1), ('b', 2), ('a', 3), ('b', 4)], key=lambda x: x[0])
for key, group in itertools.groupby(data, key=lambda x: x[0]):
    print(key, list(group))
# a [('a', 1), ('a', 3)]
# b [('b', 2), ('b', 4)]

print('done')
