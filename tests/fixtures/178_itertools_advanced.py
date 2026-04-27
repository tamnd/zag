import itertools

# chain
result = list(itertools.chain([1, 2], [3, 4], [5]))
print(result)                                          # [1, 2, 3, 4, 5]

# chain.from_iterable
result2 = list(itertools.chain.from_iterable([[1, 2], [3, 4]]))
print(result2)                                         # [1, 2, 3, 4]

# islice
result3 = list(itertools.islice(range(10), 3, 7))
print(result3)                                         # [3, 4, 5, 6]

# zip_longest
result4 = list(itertools.zip_longest([1, 2, 3], [4, 5], fillvalue=0))
print(result4)                                         # [(1, 4), (2, 5), (3, 0)]

# product
result5 = list(itertools.product([1, 2], ['a', 'b']))
print(result5)                                         # [(1, 'a'), (1, 'b'), (2, 'a'), (2, 'b')]

# permutations
result6 = sorted(itertools.permutations([1, 2, 3], 2))
print(len(result6))                                    # 6

# combinations
result7 = list(itertools.combinations([1, 2, 3, 4], 2))
print(len(result7))                                    # 6
print(result7[0])                                      # (1, 2)

# combinations_with_replacement
result8 = list(itertools.combinations_with_replacement([1, 2], 2))
print(result8)                                         # [(1, 1), (1, 2), (2, 2)]

# groupby
data = sorted([('a', 1), ('b', 2), ('a', 3), ('b', 4)], key=lambda x: x[0])
groups = {k: list(v) for k, v in itertools.groupby(data, key=lambda x: x[0])}
print(sorted(groups.keys()))                           # ['a', 'b']
print(len(groups['a']))                                # 2

# takewhile / dropwhile
result9 = list(itertools.takewhile(lambda x: x < 5, [1, 3, 5, 2]))
print(result9)                                         # [1, 3]

result10 = list(itertools.dropwhile(lambda x: x < 5, [1, 3, 5, 2]))
print(result10)                                        # [5, 2]

# count
counter = itertools.count(10, 2)
print([next(counter) for _ in range(3)])               # [10, 12, 14]

# cycle
cycler = itertools.cycle([1, 2, 3])
print([next(cycler) for _ in range(5)])                # [1, 2, 3, 1, 2]

# repeat
result11 = list(itertools.repeat(42, 3))
print(result11)                                        # [42, 42, 42]

# starmap
result12 = list(itertools.starmap(lambda a, b: a + b, [(1, 2), (3, 4)]))
print(result12)                                        # [3, 7]

# filterfalse
result13 = list(itertools.filterfalse(lambda x: x % 2, range(6)))
print(result13)                                        # [0, 2, 4]

# accumulate
result14 = list(itertools.accumulate([1, 2, 3, 4]))
print(result14)                                        # [1, 3, 6, 10]

print('done')
