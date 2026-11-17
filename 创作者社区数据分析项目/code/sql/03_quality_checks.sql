-- ============================================================================
-- 内容社区 APP 创作者成长与变现归因
-- 分层：DWD/DWS 发布前质量校验
-- 业务口径：主键、时间、漏斗、收益对账和固定种子抽样
-- 统计窗口：当前 biz_date 快照
-- 输出：质量检查明细与 PASS/FAIL；发布条件全部 PASS
-- ============================================================================

SET hivevar:biz_date=2026-02-28;
SET hivevar:data_extract_date=2026-03-31;

CREATE TABLE IF NOT EXISTS dws_quality_daily_df (
    snapshot_date       DATE COMMENT '快照日',
    check_name          STRING COMMENT '检查项',
    numerator           DECIMAL(18,8) COMMENT '异常数或子项',
    denominator         DECIMAL(18,8) COMMENT '总量或对照项',
    metric_value        DECIMAL(18,8) COMMENT '比率或差值',
    threshold           STRING COMMENT '通过阈值',
    check_status        STRING COMMENT 'PASS/FAIL',
    details             STRING COMMENT '检查说明'
)
PARTITIONED BY (dt STRING)
STORED AS PARQUET;

INSERT OVERWRITE TABLE dws_quality_daily_df PARTITION (dt='${hivevar:biz_date}')
SELECT
    CAST('${hivevar:biz_date}' AS DATE) AS snapshot_date,
    'creator_duplicate_key_cnt' AS check_name,
    COUNT(*) AS numerator,
    CAST(0 AS BIGINT) AS denominator,
    CAST(COUNT(*) AS DECIMAL(18,8)) AS metric_value,
    '0' AS threshold,
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS check_status,
    'DWD创作者表creator_id必须唯一' AS details
FROM (
    SELECT creator_id
    FROM dwd_creator_profile_df
    WHERE dt = '${hivevar:biz_date}'
    GROUP BY creator_id
    HAVING COUNT(*) > 1
) c

UNION ALL

SELECT
    CAST('${hivevar:biz_date}' AS DATE),
    'note_duplicate_key_cnt',
    COUNT(*),
    CAST(0 AS BIGINT),
    CAST(COUNT(*) AS DECIMAL(18,8)),
    '0',
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
    'DWD笔记表note_id必须唯一'
FROM (
    SELECT note_id
    FROM dwd_note_behavior_df
    WHERE dt = '${hivevar:biz_date}'
    GROUP BY note_id
    HAVING COUNT(*) > 1
) n

UNION ALL

SELECT
    CAST('${hivevar:biz_date}' AS DATE),
    'orphan_note_creator_cnt',
    COUNT(*),
    CAST(0 AS BIGINT),
    CAST(COUNT(*) AS DECIMAL(18,8)),
    '0',
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
    '可分析笔记必须能关联DWD创作者'
FROM dwd_note_behavior_df n
LEFT JOIN dwd_creator_profile_df c
  ON n.creator_id = c.creator_id
 AND c.dt = '${hivevar:biz_date}'
WHERE n.dt = '${hivevar:biz_date}'
  AND n.is_core_eligible = 1
  AND c.creator_id IS NULL

UNION ALL

SELECT
    CAST('${hivevar:biz_date}' AS DATE),
    'core_invalid_time_cnt',
    COUNT(*),
    CAST(0 AS BIGINT),
    CAST(COUNT(*) AS DECIMAL(18,8)),
    '0',
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
    '核心笔记发布时间必须合法'
FROM dwd_note_behavior_df
WHERE dt = '${hivevar:biz_date}'
  AND is_core_eligible = 1
  AND (
      publish_time IS NULL
      OR publish_time > CAST('${hivevar:data_extract_date} 23:59:59' AS TIMESTAMP)
  )

UNION ALL

SELECT
    CAST('${hivevar:biz_date}' AS DATE),
    'core_funnel_logic_error_cnt',
    COUNT(*),
    CAST(0 AS BIGINT),
    CAST(COUNT(*) AS DECIMAL(18,8)),
    '0',
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
    '核心笔记点击/曝光、买家/商品点击、退款/GMV链路必须成立'
FROM dwd_note_behavior_df
WHERE dt = '${hivevar:biz_date}'
  AND is_core_eligible = 1
  AND (
      click_uv_7d > exposure_uv_7d
      OR click_pv_7d > exposure_pv_7d
      OR paid_buyer_uv_30d > product_click_uv_30d
      OR refund_gmv_30d > gross_gmv_30d
  )

UNION ALL

SELECT
    CAST('${hivevar:biz_date}' AS DATE),
    'dwd_core_note_cnt',
    COUNT(*),
    COUNT(*),
    CAST(COUNT(*) AS DECIMAL(18,8)),
    'informational',
    'PASS',
    'DWD核心可分析笔记数'
FROM dwd_note_behavior_df
WHERE dt = '${hivevar:biz_date}'
  AND is_core_eligible = 1

UNION ALL

SELECT
    CAST('${hivevar:biz_date}' AS DATE),
    'dws_note_cnt',
    COUNT(*),
    COUNT(*),
    CAST(COUNT(*) AS DECIMAL(18,8)),
    'informational',
    'PASS',
    'DWS笔记事实行数'
FROM dws_note_traffic_conversion_df
WHERE dt = '${hivevar:biz_date}'

UNION ALL

SELECT
    CAST('${hivevar:biz_date}' AS DATE),
    'note_count_diff_dwd_vs_dws',
    ABS(
        (SELECT COUNT(*) FROM dwd_note_behavior_df
          WHERE dt = '${hivevar:biz_date}' AND is_core_eligible = 1)
        -
        (SELECT COUNT(*) FROM dws_note_traffic_conversion_df
          WHERE dt = '${hivevar:biz_date}')
    ),
    CAST(0 AS BIGINT),
    CAST(ABS(
        (SELECT COUNT(*) FROM dwd_note_behavior_df
          WHERE dt = '${hivevar:biz_date}' AND is_core_eligible = 1)
        -
        (SELECT COUNT(*) FROM dws_note_traffic_conversion_df
          WHERE dt = '${hivevar:biz_date}')
    ) AS DECIMAL(18,8)),
    '0',
    CASE WHEN ABS(
        (SELECT COUNT(*) FROM dwd_note_behavior_df
          WHERE dt = '${hivevar:biz_date}' AND is_core_eligible = 1)
        -
        (SELECT COUNT(*) FROM dws_note_traffic_conversion_df
          WHERE dt = '${hivevar:biz_date}')
    ) = 0 THEN 'PASS' ELSE 'FAIL' END,
    'DWD核心笔记与DWS笔记事实行数必须一致'

UNION ALL

SELECT
    CAST('${hivevar:biz_date}' AS DATE),
    'exposure_uv_abs_diff_dwd_vs_dws',
    ABS(
        (SELECT COALESCE(SUM(exposure_uv_7d), 0) FROM dwd_note_behavior_df
          WHERE dt = '${hivevar:biz_date}' AND is_core_eligible = 1)
        -
        (SELECT COALESCE(SUM(exposure_uv_7d), 0) FROM dws_note_traffic_conversion_df
          WHERE dt = '${hivevar:biz_date}')
    ),
    CAST(0 AS BIGINT),
    CAST(ABS(
        (SELECT COALESCE(SUM(exposure_uv_7d), 0) FROM dwd_note_behavior_df
          WHERE dt = '${hivevar:biz_date}' AND is_core_eligible = 1)
        -
        (SELECT COALESCE(SUM(exposure_uv_7d), 0) FROM dws_note_traffic_conversion_df
          WHERE dt = '${hivevar:biz_date}')
    ) AS DECIMAL(18,8)),
    '0',
    CASE WHEN ABS(
        (SELECT COALESCE(SUM(exposure_uv_7d), 0) FROM dwd_note_behavior_df
          WHERE dt = '${hivevar:biz_date}' AND is_core_eligible = 1)
        -
        (SELECT COALESCE(SUM(exposure_uv_7d), 0) FROM dws_note_traffic_conversion_df
          WHERE dt = '${hivevar:biz_date}')
    ) = 0 THEN 'PASS' ELSE 'FAIL' END,
    'DWD与DWS曝光UV必须完全对账'

UNION ALL

SELECT
    CAST('${hivevar:biz_date}' AS DATE),
    'settled_revenue_abs_diff_dwd_vs_dws',
    CAST(ABS(
        (SELECT COALESCE(SUM(
                    CASE WHEN settlement_status = '已结算'
                         THEN COALESCE(ad_revenue_30d, 0) + COALESCE(commission_revenue_30d, 0)
                         ELSE 0 END
                ), 0)
           FROM dwd_note_behavior_df
          WHERE dt = '${hivevar:biz_date}' AND is_core_eligible = 1)
        -
        (SELECT COALESCE(SUM(settled_revenue_30d), 0)
           FROM dws_note_traffic_conversion_df
          WHERE dt = '${hivevar:biz_date}')
    ) AS DECIMAL(18,8)),
    CAST(0 AS DECIMAL(18,8)),
    ABS(
        (SELECT COALESCE(SUM(
                    CASE WHEN settlement_status = '已结算'
                         THEN COALESCE(ad_revenue_30d, 0) + COALESCE(commission_revenue_30d, 0)
                         ELSE 0 END
                ), 0)
           FROM dwd_note_behavior_df
          WHERE dt = '${hivevar:biz_date}' AND is_core_eligible = 1)
        -
        (SELECT COALESCE(SUM(settled_revenue_30d), 0)
           FROM dws_note_traffic_conversion_df
          WHERE dt = '${hivevar:biz_date}')
    ),
    '0.00',
    CASE WHEN ABS(
        (SELECT COALESCE(SUM(
                    CASE WHEN settlement_status = '已结算'
                         THEN COALESCE(ad_revenue_30d, 0) + COALESCE(commission_revenue_30d, 0)
                         ELSE 0 END
                ), 0)
           FROM dwd_note_behavior_df
          WHERE dt = '${hivevar:biz_date}' AND is_core_eligible = 1)
        -
        (SELECT COALESCE(SUM(settled_revenue_30d), 0)
           FROM dws_note_traffic_conversion_df
          WHERE dt = '${hivevar:biz_date}')
    ) < 0.01 THEN 'PASS' ELSE 'FAIL' END,
    'DWD与DWS已结算创作者收益必须对账'

UNION ALL

SELECT
    CAST('${hivevar:biz_date}' AS DATE),
    'track_exposure_diff_vs_note_dws',
    ABS(
        (SELECT COALESCE(SUM(exposure_uv_7d), 0) FROM dws_track_performance_df
          WHERE dt = '${hivevar:biz_date}')
        -
        (SELECT COALESCE(SUM(exposure_uv_7d), 0) FROM dws_note_traffic_conversion_df
          WHERE dt = '${hivevar:biz_date}')
    ),
    CAST(0 AS BIGINT),
    CAST(ABS(
        (SELECT COALESCE(SUM(exposure_uv_7d), 0) FROM dws_track_performance_df
          WHERE dt = '${hivevar:biz_date}')
        -
        (SELECT COALESCE(SUM(exposure_uv_7d), 0) FROM dws_note_traffic_conversion_df
          WHERE dt = '${hivevar:biz_date}')
    ) AS DECIMAL(18,8)),
    '0',
    CASE WHEN ABS(
        (SELECT COALESCE(SUM(exposure_uv_7d), 0) FROM dws_track_performance_df
          WHERE dt = '${hivevar:biz_date}')
        -
        (SELECT COALESCE(SUM(exposure_uv_7d), 0) FROM dws_note_traffic_conversion_df
          WHERE dt = '${hivevar:biz_date}')
    ) = 0 THEN 'PASS' ELSE 'FAIL' END,
    '赛道汇总含未分类行，必须与笔记DWS总曝光对账';

-- 质量结果查看：只允许全部 PASS 后发布 DWS。
SELECT
    check_name,
    numerator,
    denominator,
    metric_value,
    threshold,
    check_status,
    details
FROM dws_quality_daily_df
WHERE dt = '${hivevar:biz_date}'
ORDER BY check_name;

-- 固定哈希种子 0.1% 抽样：结果用于人工复核，不参与 DWS 计算。
SELECT
    note_id,
    creator_id,
    publish_time,
    note_status,
    exposure_uv_7d,
    click_uv_7d,
    interaction_cnt_7d,
    product_click_uv_30d,
    paid_buyer_uv_30d,
    gross_gmv_30d,
    refund_gmv_30d,
    ad_revenue_30d,
    commission_revenue_30d,
    is_core_eligible,
    exclude_reason,
    soft_anomaly_reason,
    quality_level
FROM dwd_note_behavior_df
WHERE dt = '${hivevar:biz_date}'
  AND PMOD(HASH(CONCAT(note_id, '|dq_20261111')), 1000) = 0
ORDER BY content_category, note_id;

-- 分层抽样分布：与全量分布对比，检查抽样是否偏头或偏异常。
SELECT
    content_category,
    quality_level,
    COALESCE(exclude_reason, 'NONE') AS exclude_reason,
    COUNT(*) AS sample_cnt,
    SUM(CASE WHEN is_core_eligible = 1 THEN 1 ELSE 0 END) AS core_eligible_sample_cnt
FROM dwd_note_behavior_df
WHERE dt = '${hivevar:biz_date}'
  AND PMOD(HASH(CONCAT(note_id, '|dq_20261111')), 1000) = 0
GROUP BY content_category, quality_level, COALESCE(exclude_reason, 'NONE')
ORDER BY content_category, quality_level, exclude_reason;
