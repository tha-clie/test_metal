/*
See LICENSE folder for this sample’s licensing information.

Abstract:
Solver function for nonsymmetric nonsquare matrices.
*/


import Accelerate

/// Returns the _x_ in _Ax = b_ for a nonsquare coefficient matrix using `sgels_`.
///
/// - Parameter a: The matrix _A_ in _Ax = b_ that contains `dimension.m * dimension.n`
/// elements.
/// - Parameter dimension: The number of rows and columns of matrix _A_.
/// - Parameter b: The matrix _b_ in _Ax = b_ that contains `dimension * rightHandSideCount`
/// elements.
/// - Parameter rightHandSideCount: The number of columns in _b_.
///
/// If the system is overdeterrmined (that is, there are more rows than columns in the coefficient matrix), the
/// sum of squares of the returned elements in rows `n ..< m`is the residual sum of squares
/// for the solution.
///
/// The function specifies the leading dimension (the increment between successive columns of a matrix)
/// of matrices as their number of rows.

/// - Tag: nonsymmetric_nonsquare
func qr_decomposition(a: [Float],
                      dimension: (m: Int,
                                  n: Int)) -> ([Float]?, [Float]?) {
        
    // Create mutable copies of the parameters to pass to the LAPACK routine.
    let _m = dimension.m
    let _n = dimension.n
    var m = __CLPK_integer(_m)
    var n = __CLPK_integer(_n)
   
    // Create a mutable copy of `a` to pass to the LAPACK routine. The routine overwrites `mutableA`
    // with details of its QR or LQ factorization.
    var mutableA = a
    var lda = m
    var work = __CLPK_real(0)
    var lwork = __CLPK_integer(-1)
    var info: __CLPK_integer = 0
    
    // Call `slacpy_` to copy the values of `m * nrhs` matrix `b` into the `ldb * nrhs`
    // result matrix `x`.
    var rank = min(m, n)
    var tau = [Float](repeating: 0, count: Int(rank))

    // Pass `lwork = -1` to `sgels_` to perform a workspace query that calculates the optimal
    // size of the `work` array.
    sgeqrf_(&m, &n, &mutableA, &lda, &tau,
            &work, &lwork, &info)
    
    lwork = __CLPK_integer(work)
    
    _ = [__CLPK_real](unsafeUninitializedCapacity: Int(lwork)) {
        workspaceBuffer, workspaceInitializedCount in
    
        sgeqrf_(&m, &n, &mutableA, &lda, &tau,
                workspaceBuffer.baseAddress, &lwork, &info)
        workspaceInitializedCount = Int(lwork)
    }
    
    var R = [Float](repeating: 0, count: _m * _n)
    for i in 0..<_n {
        R[i*_m..<i*_m+i+1] = mutableA[i*_m..<i*_m+i+1]
    }
    
    // for fully QR decomposition (Q = M-by-M matrix)
    var m2 = __CLPK_integer(dimension.m)
    var Q = [Float](repeating: 0, count: _m * _m)
    Q[0..<_m*_n] = mutableA[0..<_m*_n]
    
    // Calcuate the optimal size of workspace
    lwork = __CLPK_integer(-1)
    sorgqr_(&m, &m2, &rank, &Q, &lda, &tau,
            &work, &lwork, &info)
    lwork = __CLPK_integer(work)
    
    // Generates an M-by-M real matrix Q
    _ = [__CLPK_real](unsafeUninitializedCapacity: Int(lwork)) {
        workspaceBuffer, workspaceInitializedCount in
        
        sorgqr_(&m, &m2, &rank, &Q, &lda, &tau,
                workspaceBuffer.baseAddress, &lwork, &info)
    
        workspaceInitializedCount = Int(lwork)
    }
    
    if info != 0 {
        NSLog("nonsymmetric_nonsquare error \(info)")
        return (nil, nil)
    }
    
    return (Q, R)
}

func get_orthogonal_vector(vec: [Float],
                           dimension: (m: Int,
                                       n: Int)) -> [Float]? {
    let m = dimension.m
    let n = dimension.n
    
    // Finding a basis of the null space of a matrix
    let (Q, _) = qr_decomposition(a: vec, dimension: dimension)
    var v: [Float]? = nil
    
    if let Q = Q {
        v = Array(Q[m*n..<m*n+m])
    }
    
    return v
}
