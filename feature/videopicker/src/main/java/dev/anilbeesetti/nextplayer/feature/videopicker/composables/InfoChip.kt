package dev.anilbeesetti.nextplayer.feature.videopicker.composables

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.CornerSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp

@Composable
fun InfoChip(
    text: String,
    modifier: Modifier = Modifier,
    backgroundColor: Color = MaterialTheme.colorScheme.surfaceContainerHigh,
    contentColor: Color = MaterialTheme.colorScheme.onSurface,
    shape: Shape = MaterialTheme.shapes.extraSmall.copy(all = CornerSize(2.dp)),
    // 默认跟 labelSmall 一致；只有需要更小字号的场合（比如压在文件夹图标角上）才传。
    fontSize: TextUnit? = null,
) {
    val baseStyle = MaterialTheme.typography.labelSmall.copy(fontWeight = FontWeight.Normal)
    Text(
        text = text,
        style = if (fontSize != null) baseStyle.copy(fontSize = fontSize) else baseStyle,
        color = contentColor,
        modifier = modifier
            .clip(shape = shape)
            .background(color = backgroundColor)
            .padding(
                vertical = 0.dp,
                horizontal = 3.dp,
            ),
    )
}
