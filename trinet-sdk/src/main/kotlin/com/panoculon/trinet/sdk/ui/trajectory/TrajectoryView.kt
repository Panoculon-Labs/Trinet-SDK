package com.panoculon.trinet.sdk.ui.trajectory

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Plane projection mode for [TrajectoryView2D]. Each maps world-frame XYZ to
 * a screen-space (u, v) pair:
 *   - XY: top-down (looking along −Z). u = world X, v = world Y.
 *   - XZ: side view (looking along −Y). u = world X, v = world Z (height).
 *   - YZ: alternate side. u = world Y, v = world Z. Not used in the default
 *         split layout but kept for completeness.
 */
enum class TrajectoryPlane { XY, XZ, YZ }

/**
 * 2-D orthographic projection of a 3-D trajectory polyline. Centred on the
 * current latest pose; auto-scales so the entire history fits with [marginM]
 * padding. Filter-state degraded segments draw amber, lost segments draw red.
 *
 * Compose-only: we redraw every recomposition off the [history] snapshot,
 * which is cheap up to ~4 K points (the [PoseHistory] default cap).
 */
@Composable
fun TrajectoryView2D(
    history: PoseHistory,
    plane: TrajectoryPlane,
    modifier: Modifier = Modifier,
    title: String = when (plane) {
        TrajectoryPlane.XY -> "Top (X-Y)"
        TrajectoryPlane.XZ -> "Side (X-Z)"
        TrajectoryPlane.YZ -> "Side (Y-Z)"
    },
    marginM: Float = 0.5f,
    minSpanM: Float = 1.0f,
    gridMeters: Float = 0.5f,
) {
    val surfaceBg = MaterialTheme.colorScheme.surface
    val gridColor = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.08f)
    val axisColor = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.35f)
    val labelColor = MaterialTheme.colorScheme.onSurfaceVariant
    val pathColor = MaterialTheme.colorScheme.primary
    val degradedColor = Color(0xFFD9A441)
    val lostColor = Color(0xFFB85C5C)
    val markerColor = MaterialTheme.colorScheme.tertiary

    Box(
        modifier = modifier
            .clip(RoundedCornerShape(14.dp))
            .background(surfaceBg)
    ) {
        Canvas(modifier = Modifier.fillMaxSize()) {
            val xyz = history.snapshotXYZ()
            val states = history.snapshotState()
            drawGridFrame(plane, marginM, minSpanM, gridMeters, xyz,
                gridColor = gridColor, axisColor = axisColor,
                labelColor = labelColor)
            if (xyz.isEmpty()) return@Canvas
            drawPolyline(xyz, states, plane, marginM, minSpanM,
                pathColor = pathColor, degradedColor = degradedColor,
                lostColor = lostColor)
            drawCurrentMarker(xyz, plane, marginM, minSpanM,
                markerColor = markerColor)
        }
        Text(
            text = title,
            color = labelColor,
            fontSize = 11.sp,
            modifier = Modifier
                .align(Alignment.TopStart)
                .padding(start = 10.dp, top = 8.dp),
        )
    }
}

private fun DrawScope.projectXYZ(
    x: Float, y: Float, z: Float, plane: TrajectoryPlane,
): Pair<Float, Float> = when (plane) {
    TrajectoryPlane.XY -> x to y
    TrajectoryPlane.XZ -> x to z
    TrajectoryPlane.YZ -> y to z
}

private fun DrawScope.computeBounds(
    xyz: FloatArray, plane: TrajectoryPlane, marginM: Float, minSpanM: Float,
): FloatArray {
    if (xyz.isEmpty()) {
        // Empty history: arbitrary unit box centred on origin so the grid still draws.
        val half = max(minSpanM, 1.0f) / 2f
        return floatArrayOf(-half, half, -half, half)
    }
    var uMin = Float.POSITIVE_INFINITY; var uMax = Float.NEGATIVE_INFINITY
    var vMin = Float.POSITIVE_INFINITY; var vMax = Float.NEGATIVE_INFINITY
    var i = 0
    while (i < xyz.size) {
        val (u, v) = projectXYZ(xyz[i], xyz[i + 1], xyz[i + 2], plane)
        if (u < uMin) uMin = u; if (u > uMax) uMax = u
        if (v < vMin) vMin = v; if (v > vMax) vMax = v
        i += 3
    }
    val uSpan = max(uMax - uMin, minSpanM)
    val vSpan = max(vMax - vMin, minSpanM)
    val uMid = (uMin + uMax) / 2f
    val vMid = (vMin + vMax) / 2f
    val half = max(uSpan, vSpan) / 2f + marginM
    return floatArrayOf(uMid - half, uMid + half, vMid - half, vMid + half)
}

private fun mapToScreen(
    u: Float, v: Float,
    bounds: FloatArray, widthPx: Float, heightPx: Float,
): Offset {
    val (uMin, uMax, vMin, vMax) = listOf(bounds[0], bounds[1], bounds[2], bounds[3])
    val pad = 16f
    val drawW = widthPx - 2 * pad
    val drawH = heightPx - 2 * pad
    val uSpan = (uMax - uMin).coerceAtLeast(1e-6f)
    val vSpan = (vMax - vMin).coerceAtLeast(1e-6f)
    val sx = pad + (u - uMin) / uSpan * drawW
    // Y increases downward in screen; flip v so "north" sits at the top.
    val sy = pad + (1f - (v - vMin) / vSpan) * drawH
    return Offset(sx, sy)
}

private fun DrawScope.drawGridFrame(
    plane: TrajectoryPlane,
    marginM: Float, minSpanM: Float, gridMeters: Float,
    xyz: FloatArray,
    gridColor: Color, axisColor: Color, labelColor: Color,
) {
    val bounds = computeBounds(xyz, plane, marginM, minSpanM)
    val (uMin, uMax, vMin, vMax) = listOf(bounds[0], bounds[1], bounds[2], bounds[3])

    // Vertical grid lines (constant u)
    var u = kotlin.math.floor(uMin / gridMeters) * gridMeters
    while (u <= uMax) {
        val p1 = mapToScreen(u, vMin, bounds, size.width, size.height)
        val p2 = mapToScreen(u, vMax, bounds, size.width, size.height)
        drawLine(gridColor, p1, p2, strokeWidth = 1f)
        u += gridMeters
    }
    // Horizontal grid lines (constant v)
    var v = kotlin.math.floor(vMin / gridMeters) * gridMeters
    while (v <= vMax) {
        val p1 = mapToScreen(uMin, v, bounds, size.width, size.height)
        val p2 = mapToScreen(uMax, v, bounds, size.width, size.height)
        drawLine(gridColor, p1, p2, strokeWidth = 1f)
        v += gridMeters
    }
    // Axes (u=0, v=0) if inside frame
    if (0f in uMin..uMax) {
        val p1 = mapToScreen(0f, vMin, bounds, size.width, size.height)
        val p2 = mapToScreen(0f, vMax, bounds, size.width, size.height)
        drawLine(axisColor, p1, p2, strokeWidth = 1.5f)
    }
    if (0f in vMin..vMax) {
        val p1 = mapToScreen(uMin, 0f, bounds, size.width, size.height)
        val p2 = mapToScreen(uMax, 0f, bounds, size.width, size.height)
        drawLine(axisColor, p1, p2, strokeWidth = 1.5f)
    }
}

private fun DrawScope.drawPolyline(
    xyz: FloatArray, states: IntArray, plane: TrajectoryPlane,
    marginM: Float, minSpanM: Float,
    pathColor: Color, degradedColor: Color, lostColor: Color,
) {
    val bounds = computeBounds(xyz, plane, marginM, minSpanM)
    val n = xyz.size / 3
    if (n < 2) return
    // Walk segments; colour by the END pose's filter state so a transition
    // is visible the moment it happens. Group consecutive same-coloured
    // segments into a single Path so DrawScope.drawPath is efficient.
    var segStart = 0
    while (segStart < n - 1) {
        val color = colourFor(states.getOrElse(segStart + 1) { 1 },
            pathColor, degradedColor, lostColor)
        var segEnd = segStart + 1
        while (segEnd < n - 1) {
            val c = colourFor(states.getOrElse(segEnd + 1) { 1 },
                pathColor, degradedColor, lostColor)
            if (c != color) break
            segEnd++
        }
        val path = Path()
        val (u0, v0) = projectXYZ(xyz[segStart * 3], xyz[segStart * 3 + 1], xyz[segStart * 3 + 2], plane)
        val p0 = mapToScreen(u0, v0, bounds, size.width, size.height)
        path.moveTo(p0.x, p0.y)
        var i = segStart + 1
        while (i <= segEnd) {
            val (u, v) = projectXYZ(xyz[i * 3], xyz[i * 3 + 1], xyz[i * 3 + 2], plane)
            val p = mapToScreen(u, v, bounds, size.width, size.height)
            path.lineTo(p.x, p.y)
            i++
        }
        drawPath(path, color, style = Stroke(width = 3f))
        segStart = segEnd
    }
}

private fun colourFor(
    state: Int, normal: Color, degraded: Color, lost: Color,
): Color = when (state) {
    com.panoculon.trinet.sdk.model.TriposeSample.STATE_DEGRADED -> degraded
    com.panoculon.trinet.sdk.model.TriposeSample.STATE_LOST -> lost
    else -> normal
}

private fun DrawScope.drawCurrentMarker(
    xyz: FloatArray, plane: TrajectoryPlane,
    marginM: Float, minSpanM: Float,
    markerColor: Color,
) {
    val n = xyz.size / 3
    if (n == 0) return
    val bounds = computeBounds(xyz, plane, marginM, minSpanM)
    val (u, v) = projectXYZ(xyz[(n - 1) * 3], xyz[(n - 1) * 3 + 1], xyz[(n - 1) * 3 + 2], plane)
    val p = mapToScreen(u, v, bounds, size.width, size.height)
    drawCircle(markerColor, radius = 6f, center = p)
    drawCircle(Color.White, radius = 3f, center = p)
}

/**
 * Software-projected 3D oblique view of the trajectory + a small camera
 * frustum at the latest pose. Mirrors [com.panoculon.trinet.sdk.ui.OrientationCube]'s
 * approach: rotate world points through a fixed camera, project orthographically,
 * draw via Compose Canvas — no GLES surface needed for the thumbnail.
 */
@Composable
fun TrajectoryView3D(
    history: PoseHistory,
    modifier: Modifier = Modifier,
    title: String = "3D",
    marginM: Float = 0.5f,
    minSpanM: Float = 1.0f,
) {
    val surfaceBg = MaterialTheme.colorScheme.surface
    val gridColor = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.10f)
    val labelColor = MaterialTheme.colorScheme.onSurfaceVariant
    val pathColor = MaterialTheme.colorScheme.primary
    val originColor = MaterialTheme.colorScheme.onSurfaceVariant
    val markerColor = MaterialTheme.colorScheme.tertiary

    // Fixed oblique camera: yaw 35°, pitch -25°. Good default to read all
    // three axes without needing user interaction. Roll = 0.
    val view = remember {
        buildViewMatrix(yawDeg = 35f, pitchDeg = -25f)
    }

    Box(modifier = modifier
        .clip(RoundedCornerShape(14.dp))
        .background(surfaceBg)
    ) {
        Canvas(modifier = Modifier.fillMaxSize()) {
            val xyz = history.snapshotXYZ()
            val latestQuat = history.latestQuat()
            val centre = if (xyz.isEmpty()) floatArrayOf(0f, 0f, 0f) else
                floatArrayOf(xyz[xyz.size - 3], xyz[xyz.size - 2], xyz[xyz.size - 1])

            // Compute scale once from the bounding box of the trajectory.
            val span = maxOf(
                trajectorySpan(xyz, 0), trajectorySpan(xyz, 1), trajectorySpan(xyz, 2),
                minSpanM,
            ) + marginM
            val pxPerM = (kotlin.math.min(size.width, size.height) * 0.85f) / (2f * span)
            val originScreen = Offset(size.width / 2f, size.height / 2f)

            drawGroundGrid(centre, view, pxPerM, originScreen,
                halfExtent = span, step = 0.5f, color = gridColor)
            drawWorldAxes(centre, view, pxPerM, originScreen,
                length = 0.3f, alpha = 0.7f, color = originColor)
            if (xyz.isNotEmpty()) {
                drawTrajectory3D(xyz, centre, view, pxPerM, originScreen,
                    color = pathColor)
                drawFrustum(centre, latestQuat, view, pxPerM, originScreen,
                    color = markerColor, sizeM = 0.10f)
            }
        }
        Text(
            text = title,
            color = labelColor,
            fontSize = 11.sp,
            modifier = Modifier
                .align(Alignment.TopStart)
                .padding(start = 10.dp, top = 8.dp),
        )
    }
}

/** Build a row-major 3x3 view matrix from yaw (around Z) and pitch (around X). */
private fun buildViewMatrix(yawDeg: Float, pitchDeg: Float): FloatArray {
    val y = Math.toRadians(yawDeg.toDouble()).toFloat()
    val p = Math.toRadians(pitchDeg.toDouble()).toFloat()
    val cy = cos(y); val sy = sin(y)
    val cp = cos(p); val sp = sin(p)
    // R_pitch_x · R_yaw_z applied to (x, y, z): standard z-up convention.
    return floatArrayOf(
        cy,        -sy,       0f,
        cp * sy,   cp * cy,   -sp,
        sp * sy,   sp * cy,    cp,
    )
}

private fun applyView(v: FloatArray, x: Float, y: Float, z: Float): FloatArray {
    return floatArrayOf(
        v[0] * x + v[1] * y + v[2] * z,
        v[3] * x + v[4] * y + v[5] * z,
        v[6] * x + v[7] * y + v[8] * z,
    )
}

private fun project(p: FloatArray, centre: FloatArray, view: FloatArray,
                    pxPerM: Float, origin: Offset): Offset {
    val cam = applyView(view, p[0] - centre[0], p[1] - centre[1], p[2] - centre[2])
    // Orthographic: ignore depth (cam[2]) for placement; use it only for occlusion
    // ordering downstream if we ever sort.
    val sx = origin.x + cam[0] * pxPerM
    val sy = origin.y - cam[1] * pxPerM
    return Offset(sx, sy)
}

private fun trajectorySpan(xyz: FloatArray, axis: Int): Float {
    if (xyz.isEmpty()) return 0f
    var lo = Float.POSITIVE_INFINITY; var hi = Float.NEGATIVE_INFINITY
    var i = axis
    while (i < xyz.size) {
        val v = xyz[i]
        if (v < lo) lo = v; if (v > hi) hi = v
        i += 3
    }
    return (hi - lo) / 2f
}

private fun DrawScope.drawGroundGrid(
    centre: FloatArray, view: FloatArray, pxPerM: Float, origin: Offset,
    halfExtent: Float, step: Float, color: Color,
) {
    // Grid lines on z = 0 (world XY plane) around the centre point.
    val cx0 = kotlin.math.floor((centre[0] - halfExtent) / step) * step
    val cx1 = kotlin.math.ceil((centre[0] + halfExtent) / step) * step
    val cy0 = kotlin.math.floor((centre[1] - halfExtent) / step) * step
    val cy1 = kotlin.math.ceil((centre[1] + halfExtent) / step) * step
    var u = cx0
    while (u <= cx1) {
        val a = project(floatArrayOf(u, cy0, 0f), centre, view, pxPerM, origin)
        val b = project(floatArrayOf(u, cy1, 0f), centre, view, pxPerM, origin)
        drawLine(color, a, b, strokeWidth = 1f)
        u += step
    }
    var v = cy0
    while (v <= cy1) {
        val a = project(floatArrayOf(cx0, v, 0f), centre, view, pxPerM, origin)
        val b = project(floatArrayOf(cx1, v, 0f), centre, view, pxPerM, origin)
        drawLine(color, a, b, strokeWidth = 1f)
        v += step
    }
}

private fun DrawScope.drawWorldAxes(
    centre: FloatArray, view: FloatArray, pxPerM: Float, origin: Offset,
    length: Float, alpha: Float, color: Color,
) {
    val o = project(floatArrayOf(centre[0], centre[1], centre[2]), centre, view, pxPerM, origin)
    val xs = project(floatArrayOf(centre[0] + length, centre[1], centre[2]), centre, view, pxPerM, origin)
    val ys = project(floatArrayOf(centre[0], centre[1] + length, centre[2]), centre, view, pxPerM, origin)
    val zs = project(floatArrayOf(centre[0], centre[1], centre[2] + length), centre, view, pxPerM, origin)
    drawLine(Color(0xFFB85C5C).copy(alpha = alpha), o, xs, strokeWidth = 2f)
    drawLine(Color(0xFF6B7A4B).copy(alpha = alpha), o, ys, strokeWidth = 2f)
    drawLine(Color(0xFF5C7AA8).copy(alpha = alpha), o, zs, strokeWidth = 2f)
}

private fun DrawScope.drawTrajectory3D(
    xyz: FloatArray, centre: FloatArray, view: FloatArray, pxPerM: Float,
    origin: Offset, color: Color,
) {
    val n = xyz.size / 3
    if (n < 2) return
    val path = Path()
    val p0 = project(floatArrayOf(xyz[0], xyz[1], xyz[2]), centre, view, pxPerM, origin)
    path.moveTo(p0.x, p0.y)
    var i = 1
    while (i < n) {
        val pi = project(floatArrayOf(xyz[i * 3], xyz[i * 3 + 1], xyz[i * 3 + 2]),
            centre, view, pxPerM, origin)
        path.lineTo(pi.x, pi.y)
        i++
    }
    drawPath(path, color, style = Stroke(width = 2.5f))
}

private fun DrawScope.drawFrustum(
    centre: FloatArray, quatXyzw: FloatArray, view: FloatArray,
    pxPerM: Float, origin: Offset, color: Color, sizeM: Float,
) {
    // Camera frustum corners in body frame. Trinet body frame: +X right,
    // +Y down, +Z forward (image plane convention). The frustum opens along
    // +Z so the "tip" sits at the body origin and the four corners extend
    // forward by sizeM in Z.
    val s = sizeM
    val tip = floatArrayOf(0f, 0f, 0f)
    val corners = arrayOf(
        floatArrayOf(-s, -s * 0.75f, s),
        floatArrayOf( s, -s * 0.75f, s),
        floatArrayOf( s,  s * 0.75f, s),
        floatArrayOf(-s,  s * 0.75f, s),
    )
    // Body -> world: apply pose's quaternion and translate by body origin
    // (= centre, since we already centred the view on the current pose).
    val tipW = rotateThenAdd(tip, quatXyzw, centre)
    val cw = Array(4) { rotateThenAdd(corners[it], quatXyzw, centre) }
    val tipS = project(tipW, centre, view, pxPerM, origin)
    val cs = Array(4) { project(cw[it], centre, view, pxPerM, origin) }
    // Draw edges
    for (i in 0..3) {
        drawLine(color, tipS, cs[i], strokeWidth = 2f)
        drawLine(color, cs[i], cs[(i + 1) % 4], strokeWidth = 2f)
    }
    drawCircle(color, radius = 4f, center = tipS)
}

private fun rotateThenAdd(v: FloatArray, q: FloatArray, t: FloatArray): FloatArray {
    val r = quatRotate(v[0], v[1], v[2], q)
    return floatArrayOf(r[0] + t[0], r[1] + t[1], r[2] + t[2])
}

/** Rotate (x,y,z) by quaternion (qx,qy,qz,qw). */
private fun quatRotate(x: Float, y: Float, z: Float, q: FloatArray): FloatArray {
    val qx = q[0]; val qy = q[1]; val qz = q[2]; val qw = q[3]
    val norm = sqrt(qx * qx + qy * qy + qz * qz + qw * qw)
    if (norm < 1e-6f) return floatArrayOf(x, y, z)
    val nx = qx / norm; val ny = qy / norm; val nz = qz / norm; val nw = qw / norm
    val ix =  nw * x + ny * z - nz * y
    val iy =  nw * y + nz * x - nx * z
    val iz =  nw * z + nx * y - ny * x
    val iw = -nx * x - ny * y - nz * z
    val rx = ix * nw + iw * -nx + iy * -nz - iz * -ny
    val ry = iy * nw + iw * -ny + iz * -nx - ix * -nz
    val rz = iz * nw + iw * -nz + ix * -ny - iy * -nx
    return floatArrayOf(rx, ry, rz)
}
