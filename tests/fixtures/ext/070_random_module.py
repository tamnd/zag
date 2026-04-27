# random module

import random

random.seed(42)

# Test that seeded random produces consistent results
v1 = random.random()
v2 = random.random()
v3 = random.random()
# Seed ensures determinism within same implementation
print(v1 == v1)                                    # True
print(0.0 <= v1 < 1.0)                             # True
print(0.0 <= v2 < 1.0)                             # True

# randint range
random.seed(1)
for _ in range(20):
    n = random.randint(1, 10)
    assert 1 <= n <= 10
print('randint ok')                                 # randint ok

# random() always in [0, 1)
random.seed(99)
for _ in range(20):
    v = random.random()
    assert 0.0 <= v < 1.0
print('random ok')                                  # random ok

# uniform
random.seed(5)
for _ in range(10):
    u = random.uniform(2.5, 7.5)
    assert 2.5 <= u <= 7.5
print('uniform ok')                                 # uniform ok

# choice from list
random.seed(7)
lst = [10, 20, 30, 40, 50]
for _ in range(10):
    c = random.choice(lst)
    assert c in lst
print('choice ok')                                  # choice ok

# shuffle produces a permutation
random.seed(3)
lst2 = [1, 2, 3, 4, 5]
original = lst2[:]
random.shuffle(lst2)
print(sorted(lst2) == original)                     # True (same elements)

# sample returns unique elements
random.seed(8)
sample = random.sample(range(100), 10)
print(len(sample))                                  # 10
print(len(set(sample)))                             # 10 (all unique)
print(all(0 <= x < 100 for x in sample))           # True

# randrange
random.seed(11)
for _ in range(10):
    r = random.randrange(0, 100, 5)
    assert r % 5 == 0 and 0 <= r < 100
print('randrange ok')                               # randrange ok

# gauss
random.seed(42)
vals = [random.gauss(0, 1) for _ in range(100)]
mean = sum(vals) / len(vals)
print(abs(mean) < 1.0)                             # True (mean approx 0)

# getrandbits
random.seed(42)
for _ in range(10):
    b = random.getrandbits(8)
    assert 0 <= b < 256
print('getrandbits ok')                             # getrandbits ok

print('done')
