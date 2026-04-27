import itertools

# chain
chained = list(itertools.chain([1, 2], [3, 4], [5]))
print(chained)                                        # [1, 2, 3, 4, 5]

# chain.from_iterable
nested = [[1, 2], [3, 4], [5, 6]]
flat = list(itertools.chain.from_iterable(nested))
print(flat)                                           # [1, 2, 3, 4, 5, 6]

# islice
s = list(itertools.islice(range(100), 5))
print(s)                                              # [0, 1, 2, 3, 4]

s2 = list(itertools.islice(range(100), 2, 8, 2))
print(s2)                                             # [2, 4, 6]

# product
p = list(itertools.product([1, 2], [3, 4]))
print(p)                                              # [(1, 3), (1, 4), (2, 3), (2, 4)]

p2 = list(itertools.product('AB', repeat=2))
print(len(p2))                                        # 4
print(p2[0])                                          # ('A', 'A')

# combinations
c = list(itertools.combinations([1, 2, 3, 4], 2))
print(len(c))                                         # 6
print(c[0])                                           # (1, 2)

# permutations
perm = list(itertools.permutations([1, 2, 3], 2))
print(len(perm))                                      # 6

# groupby
data = [('a', 1), ('a', 2), ('b', 3), ('b', 4), ('c', 5)]
groups = {}
for key, group in itertools.groupby(data, key=lambda x: x[0]):
    groups[key] = list(group)
print(len(groups))                                    # 3
print(groups['a'])                                    # [('a', 1), ('a', 2)]

# takewhile / dropwhile
tw = list(itertools.takewhile(lambda x: x < 5, [1, 2, 3, 4, 5, 6]))
print(tw)                                             # [1, 2, 3, 4]

dw = list(itertools.dropwhile(lambda x: x < 5, [1, 2, 3, 4, 5, 6]))
print(dw)                                             # [5, 6]

# count (first 5)
cnt = list(itertools.islice(itertools.count(10, 2), 5))
print(cnt)                                            # [10, 12, 14, 16, 18]

# cycle (first 7)
cyc = list(itertools.islice(itertools.cycle([1, 2, 3]), 7))
print(cyc)                                            # [1, 2, 3, 1, 2, 3, 1]

# repeat
rep = list(itertools.repeat(5, 3))
print(rep)                                            # [5, 5, 5]

# accumulate
acc = list(itertools.accumulate([1, 2, 3, 4, 5]))
print(acc)                                            # [1, 3, 6, 10, 15]

print('done')
