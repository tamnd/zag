# Extended builtins tests

# zip with multiple iterables
pairs = list(zip([1, 2, 3], ['a', 'b', 'c']))
print(pairs)                                          # [(1, 'a'), (2, 'b'), (3, 'c')]

# zip_longest equivalent via zip
short = list(zip([1, 2], [3, 4, 5]))
print(short)                                          # [(1, 3), (2, 4)]

# map with multiple iterables
result = list(map(lambda x, y: x + y, [1, 2, 3], [10, 20, 30]))
print(result)                                         # [11, 22, 33]

# filter
evens = list(filter(lambda x: x % 2 == 0, range(10)))
print(evens)                                          # [0, 2, 4, 6, 8]

# sorted with key
words = ['banana', 'apple', 'cherry']
print(sorted(words))                                  # ['apple', 'banana', 'cherry']
print(sorted(words, key=len))                         # ['apple', 'banana', 'cherry']
print(sorted(words, key=len, reverse=True))           # ['banana', 'cherry', 'apple']

# min, max with key
nums = [-3, 1, -2, 4]
print(min(nums, key=abs))                             # 1
print(max(nums, key=abs))                             # 4

# enumerate with start
for i, v in enumerate(['a', 'b', 'c'], start=1):
    print(i, v)
# 1 a
# 2 b
# 3 c

# any, all
print(any([False, True, False]))                      # True
print(all([True, True, True]))                        # True
print(all([True, False, True]))                       # False

# round
print(round(3.14159, 2))                              # 3.14
print(round(2.5))                                     # 2

# divmod
q, r = divmod(17, 5)
print(q, r)                                           # 3 2

# abs
print(abs(-5))                                        # 5
print(abs(-3.14))                                     # 3.14

print('done')
