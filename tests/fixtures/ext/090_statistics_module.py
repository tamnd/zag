# statistics module

import statistics

# mean
data = [1, 2, 3, 4, 5]
print(statistics.mean(data))                      # 3
print(statistics.mean([2.5, 3.5, 4.5]))           # 3.5

# median
print(statistics.median([1, 3, 5, 7, 9]))         # 5
print(statistics.median([1, 3, 5, 7]))            # 4.0

# median_low, median_high
print(statistics.median_low([1, 3, 5, 7]))        # 3
print(statistics.median_high([1, 3, 5, 7]))       # 5

# mode
print(statistics.mode([1, 2, 2, 3, 3, 3]))        # 3
print(statistics.mode(['a', 'b', 'b', 'c']))      # b

# multimode
print(sorted(statistics.multimode([1, 2, 2, 3, 3])))  # [2, 3]

# stdev and variance
data2 = [2, 4, 4, 4, 5, 5, 7, 9]
print(round(statistics.mean(data2), 1))            # 5.0
print(round(statistics.stdev(data2), 4))          # 2.0
print(round(statistics.variance(data2), 1))       # 4.0

# pstdev and pvariance (population)
print(round(statistics.pstdev([2, 4, 4, 4, 5, 5, 7, 9]), 4))   # 2.0
print(round(statistics.pvariance([2, 4, 4, 4, 5, 5, 7, 9]), 1)) # 4.0

# fmean (float mean)
print(statistics.fmean([1, 2, 3, 4, 5]))          # 3.0

# harmonic_mean
print(round(statistics.harmonic_mean([1, 2, 4]), 4))  # 1.7143

# geometric_mean
print(round(statistics.geometric_mean([1, 2, 4, 8]), 4))  # 2.8284

# quantiles
q = statistics.quantiles([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], n=4)
print([round(x, 1) for x in q])                   # [3.25, 5.5, 7.75]

print('done')
