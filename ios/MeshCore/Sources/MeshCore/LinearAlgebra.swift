import Foundation

/// Solves `a · x = b` by Gaussian elimination with partial pivoting; nil if `a` is singular.
/// Sized for the handful of unknowns the positioning code needs.
func solveLinearSystem(_ a: [[Double]], _ b: [Double]) -> [Double]? {
    let n = b.count
    guard a.count == n, a.allSatisfy({ $0.count == n }) else { return nil }
    var m = a
    var v = b
    for column in 0..<n {
        guard let pivot = (column..<n).max(by: { abs(m[$0][column]) < abs(m[$1][column]) }),
              abs(m[pivot][column]) > 1e-12 else { return nil }
        m.swapAt(column, pivot)
        v.swapAt(column, pivot)
        for row in (column + 1)..<n {
            let factor = m[row][column] / m[column][column]
            guard factor != 0 else { continue }
            for k in column..<n { m[row][k] -= factor * m[column][k] }
            v[row] -= factor * v[column]
        }
    }
    var x = [Double](repeating: 0, count: n)
    for row in stride(from: n - 1, through: 0, by: -1) {
        var sum = v[row]
        for k in (row + 1)..<n { sum -= m[row][k] * x[k] }
        x[row] = sum / m[row][row]
    }
    return x
}

/// Wraps an angle to -π...π.
func normalizedAngle(_ angle: Double) -> Double {
    atan2(sin(angle), cos(angle))
}
