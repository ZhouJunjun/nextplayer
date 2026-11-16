package dev.anilbeesetti.nextplayer.feature.videopicker.composables

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.res.vectorResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.tooling.preview.PreviewLightDark
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.anilbeesetti.nextplayer.core.common.Utils
import dev.anilbeesetti.nextplayer.core.model.ApplicationPreferences
import dev.anilbeesetti.nextplayer.core.model.Folder
import dev.anilbeesetti.nextplayer.core.model.MediaLayoutMode
import dev.anilbeesetti.nextplayer.core.ui.R
import dev.anilbeesetti.nextplayer.core.ui.components.NextSegmentedListItem
import dev.anilbeesetti.nextplayer.core.ui.theme.NextPlayerTheme

/**
 * 文件夹图标的高度，按「文件夹名最多两行」的视觉高度定。
 * 之前图标是固定 90dp 宽（20:17），比两行文字高得多；缩到这个高度后，
 * 图标与两行文字齐平，右边还能多留出空间。
 */
private val FOLDER_THUMB_HEIGHT = 48.dp

/**
 * 文件夹图标右下角「n 视频」标签的字号。
 * 比 chip 默认的 labelSmall（11sp）小一号，压在图标角上不抢戏。
 */
private val FOLDER_COUNT_FONT_SIZE = 10.sp

@Composable
fun FolderItem(
    folder: Folder,
    isRecentlyPlayedFolder: Boolean,
    preferences: ApplicationPreferences,
    modifier: Modifier = Modifier,
    isFirstItem: Boolean = false,
    isLastItem: Boolean = false,
    selected: Boolean = false,
    onClick: () -> Unit = {},
    onLongClick: (() -> Unit)? = null,
) {
    when (preferences.mediaLayoutMode) {
        MediaLayoutMode.LIST -> FolderListItem(
            folder = folder,
            isRecentlyPlayedFolder = isRecentlyPlayedFolder,
            preferences = preferences,
            modifier = modifier,
            isFirstItem = isFirstItem,
            isLastItem = isLastItem,
            selected = selected,
            onClick = onClick,
            onLongClick = onLongClick,
        )

        MediaLayoutMode.GRID -> FolderGridItem(
            folder = folder,
            isRecentlyPlayedFolder = isRecentlyPlayedFolder,
            preferences = preferences,
            modifier = modifier,
            isFirstItem = isFirstItem,
            isLastItem = isLastItem,
            selected = selected,
            onClick = onClick,
            onLongClick = onLongClick,
        )
    }
}

@OptIn(
    ExperimentalLayoutApi::class,
    ExperimentalMaterial3ExpressiveApi::class,
)
@Composable
private fun FolderListItem(
    folder: Folder,
    isRecentlyPlayedFolder: Boolean,
    preferences: ApplicationPreferences,
    modifier: Modifier = Modifier,
    isFirstItem: Boolean = false,
    isLastItem: Boolean = false,
    selected: Boolean = false,
    onClick: () -> Unit = {},
    onLongClick: (() -> Unit)? = null,
) {
    NextSegmentedListItem(
        modifier = modifier,
        selected = selected,
        contentPadding = PaddingValues(8.dp),
        colors = ListItemDefaults.segmentedColors(
            contentColor = if (isRecentlyPlayedFolder && preferences.markLastPlayedMedia) {
                MaterialTheme.colorScheme.primary
            } else {
                ListItemDefaults.colors().contentColor
            },
            supportingContentColor = if (isRecentlyPlayedFolder &&
                preferences.markLastPlayedMedia
            ) {
                MaterialTheme.colorScheme.primary
            } else {
                ListItemDefaults.colors().supportingContentColor
            },
            selectedContainerColor = MaterialTheme.colorScheme.tertiary.copy(alpha = 0.3f),
        ),
        isFirstItem = isFirstItem,
        isLastItem = isLastItem,
        onClick = onClick,
        onLongClick = onLongClick,
        leadingContent = {
            Box(modifier = Modifier.padding(horizontal = 8.dp)) {
                // 图标高度对齐「文件夹名」那两行文字的高度，所以这里不再用固定宽度 +
                // 20:17 的宽高比，而是直接给一个与两行 titleMedium 相当的高度。
                Icon(
                    imageVector = ImageVector.vectorResource(id = R.drawable.folder_thumb),
                    contentDescription = "",
                    tint = MaterialTheme.colorScheme.surfaceContainerHigh,
                    modifier = Modifier
                        .height(FOLDER_THUMB_HEIGHT)
                        .aspectRatio(ratio = 20 / 17f),
                )

                // 视频数量挪到文件夹图标的右下角。
                if (folder.videosCount > 0) {
                    InfoChip(
                        text = "${folder.videosCount} " +
                            stringResource(
                                id =
                                    R.string.video.takeIf { folder.videosCount == 1 }
                                        ?: R.string.videos,
                            ),
                        modifier = Modifier
                            .padding(2.dp)
                            .align(Alignment.BottomEnd),
                        backgroundColor = Color.Black.copy(alpha = 0.6f),
                        contentColor = Color.White,
                        shape = MaterialTheme.shapes.extraSmall,
                        // 压在图标角上，比正文 chip 小一号（labelSmall 11sp → 10sp）
                        fontSize = FOLDER_COUNT_FONT_SIZE,
                    )
                }
            }
        },
        content = {
            Text(
                text = folder.name,
                maxLines = 2,
                style = MaterialTheme.typography.titleMedium,
                overflow = TextOverflow.Ellipsis,
            )
        },
        supportingContent = {
            Column(
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                if (preferences.showPathField) {
                    Text(
                        text = folder.path.substringBeforeLast(delimiter = "/"),
                        maxLines = 1,
                        style = MaterialTheme.typography.bodySmall,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                // 视频数量已经挪到文件夹图标右下角，这里不再重复。
                FlowRow(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(5.dp),
                    verticalArrangement = Arrangement.spacedBy(5.dp),
                ) {
                    if (folder.foldersCount > 0) {
                        InfoChip(
                            text = "${folder.foldersCount} " +
                                stringResource(
                                    id =
                                        R.string.folder.takeIf { folder.foldersCount == 1 }
                                            ?: R.string.folders,
                                ),
                        )
                    }
                    if (preferences.showSizeField) {
                        InfoChip(text = Utils.formatFileSize(folder.totalSize))
                    }
                }
            }
        },
    )
}

@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
private fun FolderGridItem(
    folder: Folder,
    isRecentlyPlayedFolder: Boolean,
    preferences: ApplicationPreferences,
    modifier: Modifier = Modifier,
    isFirstItem: Boolean = false,
    isLastItem: Boolean = false,
    selected: Boolean = false,
    onClick: () -> Unit = {},
    onLongClick: (() -> Unit)? = null,
) {
    NextSegmentedListItem(
        modifier = modifier.width(IntrinsicSize.Min),
        selected = selected,
        contentPadding = PaddingValues(8.dp),
        colors = ListItemDefaults.segmentedColors(
            contentColor = if (isRecentlyPlayedFolder && preferences.markLastPlayedMedia) {
                MaterialTheme.colorScheme.primary
            } else {
                ListItemDefaults.segmentedColors().contentColor
            },
            supportingContentColor = if (isRecentlyPlayedFolder &&
                preferences.markLastPlayedMedia
            ) {
                MaterialTheme.colorScheme.primary
            } else {
                ListItemDefaults.colors().supportingContentColor
            },
            selectedContainerColor = MaterialTheme.colorScheme.tertiary.copy(alpha = 0.3f),
        ),
        isFirstItem = isFirstItem,
        isLastItem = isLastItem,
        onClick = onClick,
        onLongClick = onLongClick,
        content = {
            Column(
                modifier = modifier.fillMaxWidth(),
                verticalArrangement = Arrangement.spacedBy(8.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Box {
                    Icon(
                        imageVector = ImageVector.vectorResource(id = R.drawable.folder_thumb),
                        contentDescription = "",
                        tint = MaterialTheme.colorScheme.surfaceContainerHigh,
                        modifier = Modifier
                            .height(FOLDER_THUMB_HEIGHT)
                            .aspectRatio(ratio = 20 / 17f),
                    )

                    // 视频数量挪到文件夹图标的右下角；未读数徽标和总时长按需求去掉。
                    if (folder.videosCount > 0) {
                        InfoChip(
                            text = "${folder.videosCount} " +
                                stringResource(
                                    id =
                                        R.string.video.takeIf { folder.videosCount == 1 }
                                            ?: R.string.videos,
                                ),
                            modifier = Modifier
                                .padding(2.dp)
                                .align(Alignment.BottomEnd),
                            backgroundColor = Color.Black.copy(alpha = 0.6f),
                            contentColor = Color.White,
                            shape = MaterialTheme.shapes.extraSmall,
                            // 压在图标角上，比正文 chip 小一号（labelSmall 11sp → 10sp）
                            fontSize = FOLDER_COUNT_FONT_SIZE,
                        )
                    }
                }

                Column(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    Text(
                        text = folder.name,
                        maxLines = 2,
                        style = MaterialTheme.typography.titleMedium,
                        overflow = TextOverflow.Ellipsis,
                        color = if (isRecentlyPlayedFolder && preferences.markLastPlayedMedia) {
                            MaterialTheme.colorScheme.primary
                        } else {
                            ListItemDefaults.colors().contentColor
                        },
                        textAlign = TextAlign.Center,
                    )
                    // 视频数量已经画在文件夹图标右下角，这里只留子文件夹数量。
                    if (folder.foldersCount > 0) {
                        Text(
                            text = "${folder.foldersCount} " +
                                stringResource(
                                    id =
                                        R.string.folder.takeIf { folder.foldersCount == 1 }
                                            ?: R.string.folders,
                                ),
                            maxLines = 1,
                            style = MaterialTheme.typography.labelSmall.copy(
                                fontWeight = FontWeight.Normal,
                            ),
                            textAlign = TextAlign.Center,
                        )
                    }
                }
            }
        },
    )
}

@PreviewLightDark
@Composable
fun FolderItemRecentlyPlayedPreview() {
    NextPlayerTheme {
        FolderListItem(
            folder = Folder.sample,
            preferences = ApplicationPreferences(),
            isRecentlyPlayedFolder = true,
        )
    }
}

@PreviewLightDark
@Composable
fun FolderItemPreview() {
    NextPlayerTheme {
        FolderListItem(
            folder = Folder.sample,
            preferences = ApplicationPreferences(),
            isRecentlyPlayedFolder = false,
        )
    }
}

@PreviewLightDark
@Composable
fun FolderGridViewPreview() {
    NextPlayerTheme {
        FolderGridItem(
            folder = Folder.sample,
            preferences = ApplicationPreferences(),
            isRecentlyPlayedFolder = true,
        )
    }
}

