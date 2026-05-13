package com.panoculon.trinet.sdk.ui

import androidx.compose.foundation.Canvas
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import kotlin.math.min

/**
 * Lightweight quaternion-driven orientation widget. Rather than spin up a GLES
 * surface for a single rotated cube, we project a unit cube's vertices through
 * the active rotation in pure software — well within Compose budget for a small
 * sidebar widget refreshed at 30 Hz.
 *
 * [quatXyzw] is XYZW unit quaternion (matches the device's lin_accel storage).
 */
@Composable
fun OrientationCube(
    quatXyzw: FloatArray,
    modifier: Modifier = Modifier,
    color: Color = Color(0xFF6B7A4B),
) {
    val cubeVerts = remember {
        floatArrayOf(
            -1f, -1f, -1f,  1f, -1f, -1f,  1f,  1f, -1f, -1f,  1f, -1f,
            -1f, -1f,  1f,  1f, -1f,  1f,  1f,  1f,  1f, -1f,  1f,  1f,
        )
    }
    val edges = remember {
        intArrayOf(
            0,1, 1,2, 2,3, 3,0,   // back face
            4,5, 5,6, 6,7, 7,4,   // front face
            0,4, 1,5, 2,6, 3,7,   // connectors
        )
    }
    Canvas(modifier = modifier) {
        val cx = size.width / 2f
        val cy = size.height / 2f
        val scale = min(cx, cy) * 0.55f

        val rotated = FloatArray(cubeVerts.size)
        var i = 0
        while (i < cubeVerts.size) {
            val (rx, ry, rz) = rotate(cubeVerts[i], cubeVerts[i + 1], cubeVerts[i + 2], quatXyzw)
            rotated[i] = rx; rotated[i + 1] = ry; rotated[i + 2] = rz
            i += 3
        }

        val proj = FloatArray(2 * (cubeVerts.size / 3))
        var pi = 0
        var vi = 0
        while (vi < rotated.size) {
            // Simple orthographic projection from +Y axis (camera looking down -Y).
            proj[pi] = cx + rotated[vi] * scale
            proj[pi + 1] = cy - rotated[vi + 2] * scale
            pi += 2; vi += 3
        }

        val path = Path()
        var e = 0
        while (e < edges.size) {
            val a = edges[e]; val b = edges[e + 1]
            path.moveTo(proj[a * 2], proj[a * 2 + 1])
            path.lineTo(proj[b * 2], proj[b * 2 + 1])
            e += 2
        }
        drawPath(path = path, color = color, style = Stroke(width = 2.5f))

        // Tiny axis indicator at the center
        val axisLen = scale * 0.3f
        val (xx, _, xz) = rotate(1f, 0f, 0f, quatXyzw)
        val (zx, _, zz) = rotate(0f, 0f, 1f, quatXyzw)
        drawLine(Color(0xFFB85C5C), Offset(cx, cy), Offset(cx + xx * axisLen, cy - xz * axisLen), strokeWidth = 2f)
        drawLine(Color(0xFF5C7AA8), Offset(cx, cy), Offset(cx + zx * axisLen, cy - zz * axisLen), strokeWidth = 2f)
    }
}

/** Rotate vector (x,y,z) by quaternion (qx,qy,qz,qw). */
private fun rotate(x: Float, y: Float, z: Float, q: FloatArray): Triple<Float, Float, Float> {
    val qx = q[0]; val qy = q[1]; val qz = q[2]; val qw = q[3]
    // v' = q * v * q^-1
    val ix =  qw * x + qy * z - qz * y
    val iy =  qw * y + qz * x - qx * z
    val iz =  qw * z + qx * y - qy * x
    val iw = -qx * x - qy * y - qz * z
    val rx = ix * qw + iw * -qx + iy * -qz - iz * -qy
    val ry = iy * qw + iw * -qy + iz * -qx - ix * -qz
    val rz = iz * qw + iw * -qz + ix * -qy - iy * -qx
    return Triple(rx, ry, rz)
}
