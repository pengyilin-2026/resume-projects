-- ============================================================================
-- 内容社区 APP 创作者成长与变现归因
-- 分层：DWD -> DWS
-- 业务口径：仅消费 is_core_eligible=1 的创作者和笔记
-- 统计窗口：2025-09-01~2026-03-31 行为提取窗；快照 2026-02-28
-- 输出：创作者生命周期、创作者分层、笔记转化、赛道、新人留存 DWS
-- 依赖：sql/01_ods_to_dwd.sql 已执行
-- ============================================================================

SET hivevar:biz_date=2026-02-28;
SET hivevar:feature_start=2025-09-01;
SET hivevar:feature_end=2026-01-31;
SET hivevar:label_start=2026-02-01;
SET hivevar:label_end=2026-02-28;
SET hivevar:data_extract_date=2026-03-31;
SET hivevar:metric_version=dws_v1.0;

-- ----------------------------------------------------------------------------
-- 分层：DWS
-- 业务口径：创作者生命周期与留存
-- 创作周期：首末有效发文日历跨度；连续创作：相邻活跃日间隔<=7天的活动段最大跨度
-- 留存窗口：首篇后D1-D7/D1-D14再次发布有效笔记；未成熟不计入分母
-- 输出：每位创作者的首次、末次、周期、静默、D7/D14、28日流失和分层
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dws_creator_lifecycle_df (
    snapshot_date                 DATE COMMENT '快照日',
    creator_id                    STRING COMMENT '创作者ID',
    user_id                       STRING COMMENT '用户ID',
    cohort_month                  STRING COMMENT '新人首月或存量观察月',
    is_new_creator                INT COMMENT '新人1/0',
    primary_category              STRING COMMENT '创作者主类目',
    support_group                 STRING COMMENT '扶持组',
    first_valid_publish_at        TIMESTAMP COMMENT '首篇有效公开笔记时间',
    last_valid_publish_at         TIMESTAMP COMMENT '末篇有效公开笔记时间',
    creator_tenure_days           INT COMMENT '入行周期，首篇到快照日',
    create_span_days              INT COMMENT '首末发文日历跨度',
    continuous_creation_days      INT COMMENT '允许7日间隔的连续创作段最大跨度',
    silent_days                   INT COMMENT '快照日距末次发文天数',
    last_active_month             STRING COMMENT '末次发文所在月',
    active_day_cnt                INT COMMENT '有效发文去重天数',
    valid_note_cnt_28d            BIGINT COMMENT '快照前28日有效笔记数',
    feature_note_cnt              BIGINT COMMENT '特征窗有效笔记数',
    feature_exposure_uv           BIGINT COMMENT '特征窗笔记曝光UV贡献',
    feature_click_uv              BIGINT COMMENT '特征窗笔记点击UV贡献',
    feature_interaction_cnt       BIGINT COMMENT '特征窗互动量',
    settled_revenue_feature       DECIMAL(18,2) COMMENT '特征窗已结算广告+佣金',
    monetizing_flag               INT COMMENT '特征窗是否变现1/0',
    retained_7d                   INT COMMENT '首篇后D1-D7是否再次发布',
    retained_7d_eligible          INT COMMENT 'D7是否成熟',
    retained_14d                  INT COMMENT '首篇后D1-D14是否再次发布',
    retained_14d_eligible         INT COMMENT 'D14是否成熟',
    churn_28d                     INT COMMENT '2月28日停更标签',
    churn_label_eligible          INT COMMENT '流失标签是否适用',
    creator_tier                  STRING COMMENT '新人/头部/腰部/尾部/不活跃存量',
    creator_tier_decile           INT COMMENT '存量按曝光降序十分位，1最高',
    quality_level                 STRING COMMENT '质量等级',
    metric_version                STRING COMMENT '指标版本'
)
PARTITIONED BY (dt STRING)
STORED AS PARQUET;

WITH creator_base AS (
    SELECT *
    FROM dwd_creator_profile_df
    WHERE dt = '${hivevar:biz_date}'
      AND is_core_eligible = 1
),
note_core AS (
    SELECT
        n.*
    FROM dwd_note_behavior_df n
    JOIN creator_base c
      ON n.creator_id = c.creator_id
    WHERE n.dt = '${hivevar:biz_date}'
      AND n.is_core_eligible = 1
      AND n.publish_time >= '${hivevar:feature_start} 00:00:00'
      AND n.publish_time <= CAST('${hivevar:data_extract_date} 23:59:59' AS TIMESTAMP)
),
creator_note_stats AS (
    SELECT
        creator_id,
        MIN(publish_time) AS first_valid_publish_at,
        MAX(publish_time) AS last_valid_publish_at,
        COUNT(*) AS valid_note_cnt,
        COUNT(DISTINCT TO_DATE(publish_time)) AS active_day_cnt,
        COUNT(CASE WHEN publish_time >= DATE_SUB('${hivevar:biz_date}', 27) THEN 1 END) AS valid_note_cnt_28d,
        COUNT(CASE WHEN publish_time >= '${hivevar:feature_start} 00:00:00'
                    AND publish_time <= '${hivevar:feature_end} 23:59:59' THEN 1 END) AS feature_note_cnt,
        SUM(CASE WHEN publish_time >= '${hivevar:feature_start} 00:00:00'
                  AND publish_time <= '${hivevar:feature_end} 23:59:59'
                 THEN COALESCE(exposure_uv_7d, 0) ELSE 0 END) AS feature_exposure_uv,
        SUM(CASE WHEN publish_time >= '${hivevar:feature_start} 00:00:00'
                  AND publish_time <= '${hivevar:feature_end} 23:59:59'
                 THEN COALESCE(click_uv_7d, 0) ELSE 0 END) AS feature_click_uv,
        SUM(CASE WHEN publish_time >= '${hivevar:feature_start} 00:00:00'
                  AND publish_time <= '${hivevar:feature_end} 23:59:59'
                 THEN COALESCE(interaction_cnt_7d, 0) ELSE 0 END) AS feature_interaction_cnt,
        SUM(CASE WHEN publish_time >= '${hivevar:feature_start} 00:00:00'
                  AND publish_time <= '${hivevar:feature_end} 23:59:59'
                  AND settlement_status = '已结算'
                 THEN COALESCE(ad_revenue_30d, 0) + COALESCE(commission_revenue_30d, 0)
                 ELSE 0 END) AS settled_revenue_feature
    FROM note_core
    GROUP BY creator_id
),
daily_active AS (
    SELECT DISTINCT creator_id, TO_DATE(publish_time) AS active_date
    FROM note_core
),
active_lag AS (
    SELECT
        creator_id,
        active_date,
        LAG(active_date, 1) OVER (PARTITION BY creator_id ORDER BY active_date) AS prev_active_date
    FROM daily_active
),
active_run_group AS (
    SELECT
        creator_id,
        active_date,
        SUM(
            CASE
                WHEN prev_active_date IS NULL THEN 0
                WHEN DATEDIFF(active_date, prev_active_date) > 7 THEN 1
                ELSE 0
            END
        ) OVER (
            PARTITION BY creator_id
            ORDER BY active_date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS run_group
    FROM active_lag
),
active_runs AS (
    SELECT
        creator_id,
        run_group,
        DATEDIFF(MAX(active_date), MIN(active_date)) + 1 AS run_span_days
    FROM active_run_group
    GROUP BY creator_id, run_group
),
continuous_stats AS (
    SELECT
        creator_id,
        MAX(run_span_days) AS continuous_creation_days
    FROM active_runs
    GROUP BY creator_id
),
first_note AS (
    SELECT
        creator_id,
        first_valid_publish_at
    FROM creator_note_stats
),
retention_flags AS (
    SELECT
        f.creator_id,
        MAX(CASE WHEN DATEDIFF(TO_DATE(n.publish_time), TO_DATE(f.first_valid_publish_at)) BETWEEN 1 AND 7
                 THEN 1 ELSE 0 END) AS retained_7d,
        MAX(CASE WHEN DATEDIFF(TO_DATE(n.publish_time), TO_DATE(f.first_valid_publish_at)) BETWEEN 1 AND 14
                 THEN 1 ELSE 0 END) AS retained_14d
    FROM first_note f
    LEFT JOIN note_core n
      ON f.creator_id = n.creator_id
     AND TO_DATE(n.publish_time) <= DATE_ADD(TO_DATE(f.first_valid_publish_at), 14)
    GROUP BY f.creator_id
),
creator_metrics AS (
    SELECT
        c.creator_id,
        c.user_id,
        c.snapshot_date,
        c.cohort_month,
        c.is_new_creator,
        c.primary_category,
        c.support_group,
        s.first_valid_publish_at,
        s.last_valid_publish_at,
        DATEDIFF(c.snapshot_date, TO_DATE(s.first_valid_publish_at)) + 1 AS creator_tenure_days,
        DATEDIFF(TO_DATE(s.last_valid_publish_at), TO_DATE(s.first_valid_publish_at)) + 1 AS create_span_days,
        COALESCE(cs.continuous_creation_days, 1) AS continuous_creation_days,
        GREATEST(DATEDIFF(c.snapshot_date, TO_DATE(s.last_valid_publish_at)), 0) AS silent_days,
        SUBSTR(CAST(s.last_valid_publish_at AS STRING), 1, 7) AS last_active_month,
        s.active_day_cnt,
        s.valid_note_cnt_28d,
        s.feature_note_cnt,
        s.feature_exposure_uv,
        s.feature_click_uv,
        s.feature_interaction_cnt,
        s.settled_revenue_feature,
        CASE WHEN s.settled_revenue_feature > 0 THEN 1 ELSE 0 END AS monetizing_flag,
        CASE
            WHEN c.is_new_creator = 1
             AND DATEDIFF(c.snapshot_date, TO_DATE(s.first_valid_publish_at)) >= 7
            THEN COALESCE(r.retained_7d, 0) ELSE NULL
        END AS retained_7d,
        CASE
            WHEN c.is_new_creator = 1
             AND DATEDIFF(c.snapshot_date, TO_DATE(s.first_valid_publish_at)) >= 7
            THEN 1 ELSE 0
        END AS retained_7d_eligible,
        CASE
            WHEN c.is_new_creator = 1
             AND DATEDIFF(c.snapshot_date, TO_DATE(s.first_valid_publish_at)) >= 14
            THEN COALESCE(r.retained_14d, 0) ELSE NULL
        END AS retained_14d,
        CASE
            WHEN c.is_new_creator = 1
             AND DATEDIFF(c.snapshot_date, TO_DATE(s.first_valid_publish_at)) >= 14
            THEN 1 ELSE 0
        END AS retained_14d_eligible,
        c.churn_28d,
        c.source_churn_label_eligible AS churn_label_eligible,
        c.quality_level
    FROM creator_base c
    JOIN creator_note_stats s
      ON c.creator_id = s.creator_id
    LEFT JOIN continuous_stats cs
      ON c.creator_id = cs.creator_id
    LEFT JOIN retention_flags r
      ON c.creator_id = r.creator_id
),
tier_ranked AS (
    SELECT
        m.*,
        CASE
            WHEN m.is_new_creator = 1 THEN NULL
            WHEN m.feature_note_cnt = 0 THEN NULL
            ELSE NTILE(10) OVER (
                PARTITION BY m.snapshot_date, m.is_new_creator
                ORDER BY m.feature_exposure_uv DESC, m.settled_revenue_feature DESC, m.creator_id
            )
        END AS tier_decile
    FROM creator_metrics m
)
INSERT OVERWRITE TABLE dws_creator_lifecycle_df PARTITION (dt='${hivevar:biz_date}')
SELECT
    t.snapshot_date,
    t.creator_id,
    t.user_id,
    t.cohort_month,
    t.is_new_creator,
    t.primary_category,
    t.support_group,
    t.first_valid_publish_at,
    t.last_valid_publish_at,
    t.creator_tenure_days,
    t.create_span_days,
    t.continuous_creation_days,
    t.silent_days,
    t.last_active_month,
    t.active_day_cnt,
    t.valid_note_cnt_28d,
    t.feature_note_cnt,
    t.feature_exposure_uv,
    t.feature_click_uv,
    t.feature_interaction_cnt,
    t.settled_revenue_feature,
    t.monetizing_flag,
    t.retained_7d,
    t.retained_7d_eligible,
    t.retained_14d,
    t.retained_14d_eligible,
    t.churn_28d,
    t.churn_label_eligible,
    CASE
        WHEN t.is_new_creator = 1 THEN '新人'
        WHEN t.tier_decile BETWEEN 1 AND 1 THEN '头部'
        WHEN t.tier_decile BETWEEN 2 AND 5 THEN '腰部'
        WHEN t.tier_decile BETWEEN 6 AND 10 THEN '尾部'
        ELSE '不活跃存量'
    END AS creator_tier,
    t.tier_decile AS creator_tier_decile,
    t.quality_level,
    '${hivevar:metric_version}' AS metric_version
FROM tier_ranked t;

-- ----------------------------------------------------------------------------
-- 分层：DWS
-- 业务口径：创作者分层聚合
-- 活跃：特征窗至少1篇有效公开笔记；ARPU=已结算创作者收益/活跃创作者数
-- 留存：仅新人有D7/D14；头部/腰部/尾部为相对曝光分层，不强行赋留存
-- 输出：各层级规模、供给、收益、单篇收益和新人留存
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dws_creator_segment_df (
    snapshot_date                 DATE,
    creator_tier                  STRING,
    creator_cnt                   BIGINT,
    creator_share                 DECIMAL(12,8),
    active_creator_cnt            BIGINT,
    active_creator_share          DECIMAL(12,8),
    new_creator_cnt               BIGINT,
    new_creator_share             DECIMAL(12,8),
    feature_note_cnt              BIGINT,
    avg_notes_per_creator         DECIMAL(18,4),
    avg_active_days               DECIMAL(18,4),
    settled_revenue               DECIMAL(18,2),
    creator_arpu                  DECIMAL(18,4),
    single_note_avg_revenue       DECIMAL(18,4),
    monetizing_creator_cnt        BIGINT,
    retention_7d_eligible_cnt     BIGINT,
    retained_7d_cnt               BIGINT,
    retention_7d_rate             DECIMAL(12,8),
    retention_14d_eligible_cnt    BIGINT,
    retained_14d_cnt              BIGINT,
    retention_14d_rate            DECIMAL(12,8),
    churn_eligible_cnt            BIGINT,
    churn_cnt                     BIGINT,
    churn_28d_rate                DECIMAL(12,8),
    metric_version                STRING
)
PARTITIONED BY (dt STRING)
STORED AS PARQUET;

WITH segment_base AS (
    SELECT *
    FROM dws_creator_lifecycle_df
    WHERE dt = '${hivevar:biz_date}'
      AND creator_tier IN ('新人','头部','腰部','尾部')
),
totals AS (
    SELECT
        COUNT(*) AS total_creator_cnt,
        SUM(CASE WHEN feature_note_cnt > 0 THEN 1 ELSE 0 END) AS total_active_creator_cnt,
        SUM(CASE WHEN is_new_creator = 1 THEN 1 ELSE 0 END) AS total_new_creator_cnt
    FROM segment_base
)
INSERT OVERWRITE TABLE dws_creator_segment_df PARTITION (dt='${hivevar:biz_date}')
SELECT
    s.snapshot_date,
    s.creator_tier,
    COUNT(*) AS creator_cnt,
    CAST(COUNT(*) AS DECIMAL(18,8)) / CAST(t.total_creator_cnt AS DECIMAL(18,8)) AS creator_share,
    SUM(CASE WHEN s.feature_note_cnt > 0 THEN 1 ELSE 0 END) AS active_creator_cnt,
    CAST(SUM(CASE WHEN s.feature_note_cnt > 0 THEN 1 ELSE 0 END) AS DECIMAL(18,8))
      / CAST(NULLIF(t.total_active_creator_cnt, 0) AS DECIMAL(18,8)) AS active_creator_share,
    SUM(CASE WHEN s.is_new_creator = 1 THEN 1 ELSE 0 END) AS new_creator_cnt,
    CAST(SUM(CASE WHEN s.is_new_creator = 1 THEN 1 ELSE 0 END) AS DECIMAL(18,8))
      / CAST(NULLIF(t.total_new_creator_cnt, 0) AS DECIMAL(18,8)) AS new_creator_share,
    SUM(s.feature_note_cnt) AS feature_note_cnt,
    CASE
        WHEN SUM(CASE WHEN s.feature_note_cnt > 0 THEN 1 ELSE 0 END) = 0 THEN NULL
        ELSE CAST(SUM(s.feature_note_cnt) AS DECIMAL(18,4))
             / CAST(SUM(CASE WHEN s.feature_note_cnt > 0 THEN 1 ELSE 0 END) AS DECIMAL(18,4))
    END AS avg_notes_per_creator,
    CASE
        WHEN SUM(CASE WHEN s.feature_note_cnt > 0 THEN 1 ELSE 0 END) = 0 THEN NULL
        ELSE CAST(SUM(CASE WHEN s.feature_note_cnt > 0 THEN s.active_day_cnt ELSE 0 END) AS DECIMAL(18,4))
             / CAST(SUM(CASE WHEN s.feature_note_cnt > 0 THEN 1 ELSE 0 END) AS DECIMAL(18,4))
    END AS avg_active_days,
    SUM(s.settled_revenue_feature) AS settled_revenue,
    CASE
        WHEN SUM(CASE WHEN s.feature_note_cnt > 0 THEN 1 ELSE 0 END) = 0 THEN NULL
        ELSE CAST(SUM(s.settled_revenue_feature) AS DECIMAL(18,4))
             / CAST(SUM(CASE WHEN s.feature_note_cnt > 0 THEN 1 ELSE 0 END) AS DECIMAL(18,4))
    END AS creator_arpu,
    CASE
        WHEN SUM(s.feature_note_cnt) = 0 THEN NULL
        ELSE CAST(SUM(s.settled_revenue_feature) AS DECIMAL(18,4))
             / CAST(SUM(s.feature_note_cnt) AS DECIMAL(18,4))
    END AS single_note_avg_revenue,
    SUM(CASE WHEN s.monetizing_flag = 1 THEN 1 ELSE 0 END) AS monetizing_creator_cnt,
    SUM(s.retained_7d_eligible) AS retention_7d_eligible_cnt,
    SUM(COALESCE(s.retained_7d, 0)) AS retained_7d_cnt,
    CASE
        WHEN SUM(s.retained_7d_eligible) = 0 THEN NULL
        ELSE CAST(SUM(COALESCE(s.retained_7d, 0)) AS DECIMAL(18,8))
             / CAST(SUM(s.retained_7d_eligible) AS DECIMAL(18,8))
    END AS retention_7d_rate,
    SUM(s.retained_14d_eligible) AS retention_14d_eligible_cnt,
    SUM(COALESCE(s.retained_14d, 0)) AS retained_14d_cnt,
    CASE
        WHEN SUM(s.retained_14d_eligible) = 0 THEN NULL
        ELSE CAST(SUM(COALESCE(s.retained_14d, 0)) AS DECIMAL(18,8))
             / CAST(SUM(s.retained_14d_eligible) AS DECIMAL(18,8))
    END AS retention_14d_rate,
    SUM(s.churn_label_eligible) AS churn_eligible_cnt,
    SUM(COALESCE(s.churn_28d, 0)) AS churn_cnt,
    CASE
        WHEN SUM(s.churn_label_eligible) = 0 THEN NULL
        ELSE CAST(SUM(COALESCE(s.churn_28d, 0)) AS DECIMAL(18,8))
             / CAST(SUM(s.churn_label_eligible) AS DECIMAL(18,8))
    END AS churn_28d_rate,
    '${hivevar:metric_version}' AS metric_version
FROM segment_base s
CROSS JOIN totals t
GROUP BY s.snapshot_date, s.creator_tier, t.total_creator_cnt, t.total_active_creator_cnt,
         t.total_new_creator_cnt;

-- ----------------------------------------------------------------------------
-- 分层：DWS
-- 业务口径：笔记粒度流量、互动、成交和收益
-- 窗口：曝光/点击/互动为发布后7日；成交/收益为发布后30日
-- 毛利：当前缺成本字段，不生成伪毛利；提供创作者收益贡献代理
-- 输出：每条可分析笔记的指标和创作者层级
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dws_note_traffic_conversion_df (
    snapshot_date                   DATE,
    note_id                         STRING,
    creator_id                      STRING,
    creator_tier                    STRING,
    publish_time                    TIMESTAMP,
    content_type                    STRING,
    content_category                STRING,
    algorithm_version               STRING,
    distribution_pool               STRING,
    exposure_uv_7d                  BIGINT,
    click_uv_7d                     BIGINT,
    ctr                             DECIMAL(18,10),
    positive_interaction_cnt        BIGINT,
    positive_interaction_rate       DECIMAL(18,10),
    follow_conversion_rate          DECIMAL(18,10),
    product_click_uv_30d            BIGINT,
    product_click_rate              DECIMAL(18,10),
    paid_buyer_uv_30d               BIGINT,
    commerce_conversion_rate        DECIMAL(18,10),
    net_gmv_30d                     DECIMAL(18,2),
    ad_revenue_30d                  DECIMAL(18,2),
    commission_revenue_30d          DECIMAL(18,2),
    settled_revenue_30d             DECIMAL(18,2),
    note_contribution_revenue_30d   DECIMAL(18,2),
    note_gross_profit               DECIMAL(18,2),
    note_gross_profit_status        STRING,
    note_monetization_efficiency    DECIMAL(18,8),
    gmv_per_1k_exposure             DECIMAL(18,8),
    negative_feedback_rate          DECIMAL(18,10),
    metric_window_complete          INT,
    quality_level                   STRING,
    metric_version                  STRING
)
PARTITIONED BY (dt STRING)
STORED AS PARQUET;

INSERT OVERWRITE TABLE dws_note_traffic_conversion_df PARTITION (dt='${hivevar:biz_date}')
SELECT
    c.snapshot_date,
    n.note_id,
    n.creator_id,
    c.creator_tier,
    n.publish_time,
    n.content_type,
    n.content_category,
    n.algorithm_version,
    n.distribution_pool,
    n.exposure_uv_7d,
    n.click_uv_7d,
    CASE
        WHEN COALESCE(n.exposure_uv_7d, 0) = 0 THEN NULL
        ELSE CAST(n.click_uv_7d AS DECIMAL(18,10)) / CAST(n.exposure_uv_7d AS DECIMAL(18,10))
    END AS ctr,
    n.interaction_cnt_7d AS positive_interaction_cnt,
    CASE
        WHEN COALESCE(n.click_uv_7d, 0) = 0 THEN NULL
        ELSE CAST(n.interaction_cnt_7d AS DECIMAL(18,10)) / CAST(n.click_uv_7d AS DECIMAL(18,10))
    END AS positive_interaction_rate,
    CASE
        WHEN COALESCE(n.click_uv_7d, 0) = 0 THEN NULL
        ELSE CAST(n.follow_cnt_7d AS DECIMAL(18,10)) / CAST(n.click_uv_7d AS DECIMAL(18,10))
    END AS follow_conversion_rate,
    n.product_click_uv_30d,
    CASE
        WHEN COALESCE(n.click_uv_7d, 0) = 0 THEN NULL
        ELSE CAST(n.product_click_uv_30d AS DECIMAL(18,10)) / CAST(n.click_uv_7d AS DECIMAL(18,10))
    END AS product_click_rate,
    n.paid_buyer_uv_30d,
    CASE
        WHEN COALESCE(n.product_click_uv_30d, 0) = 0 THEN NULL
        ELSE CAST(n.paid_buyer_uv_30d AS DECIMAL(18,10)) / CAST(n.product_click_uv_30d AS DECIMAL(18,10))
    END AS commerce_conversion_rate,
    n.net_gmv_30d,
    CASE WHEN n.settlement_status = '已结算' THEN COALESCE(n.ad_revenue_30d, 0)
         ELSE CAST(0 AS DECIMAL(18,2)) END AS ad_revenue_30d,
    CASE WHEN n.settlement_status = '已结算' THEN COALESCE(n.commission_revenue_30d, 0)
         ELSE CAST(0 AS DECIMAL(18,2)) END AS commission_revenue_30d,
    CASE
        WHEN n.settlement_status = '已结算'
        THEN COALESCE(n.ad_revenue_30d, 0) + COALESCE(n.commission_revenue_30d, 0)
        ELSE CAST(0 AS DECIMAL(18,2))
    END AS settled_revenue_30d,
    CASE
        WHEN n.settlement_status = '已结算'
        THEN COALESCE(n.ad_revenue_30d, 0) + COALESCE(n.commission_revenue_30d, 0)
        ELSE CAST(0 AS DECIMAL(18,2))
    END AS note_contribution_revenue_30d,
    CAST(NULL AS DECIMAL(18,2)) AS note_gross_profit,
    'BLOCKED_MISSING_COST_FIELD' AS note_gross_profit_status,
    CASE
        WHEN COALESCE(n.exposure_uv_7d, 0) = 0 THEN NULL
        ELSE CAST(
            CASE WHEN n.settlement_status = '已结算'
                 THEN COALESCE(n.ad_revenue_30d, 0) + COALESCE(n.commission_revenue_30d, 0)
                 ELSE 0 END AS DECIMAL(18,8)
        ) * 1000 / CAST(n.exposure_uv_7d AS DECIMAL(18,8))
    END AS note_monetization_efficiency,
    CASE
        WHEN COALESCE(n.exposure_uv_7d, 0) = 0 THEN NULL
        ELSE CAST(n.net_gmv_30d AS DECIMAL(18,8)) * 1000 / CAST(n.exposure_uv_7d AS DECIMAL(18,8))
    END AS gmv_per_1k_exposure,
    CASE
        WHEN COALESCE(n.exposure_pv_7d, 0) = 0 THEN NULL
        ELSE CAST(n.negative_feedback_cnt_7d AS DECIMAL(18,10)) / CAST(n.exposure_pv_7d AS DECIMAL(18,10))
    END AS negative_feedback_rate,
    CASE
        WHEN n.traffic_window_end_date <= '${hivevar:data_extract_date}'
         AND n.commerce_window_end_date <= '${hivevar:data_extract_date}' THEN 1 ELSE 0
    END AS metric_window_complete,
    n.quality_level,
    '${hivevar:metric_version}' AS metric_version
FROM dwd_note_behavior_df n
JOIN dws_creator_lifecycle_df c
  ON n.creator_id = c.creator_id
 AND c.dt = '${hivevar:biz_date}'
WHERE n.dt = '${hivevar:biz_date}'
  AND n.is_core_eligible = 1;

-- ----------------------------------------------------------------------------
-- 分层：DWS
-- 业务口径：新人首篇表现分群
-- 首篇：新人分析窗内最早有效公开笔记
-- 分群：同首月同赛道内首篇曝光五分组×首篇点击后互动五分组
-- 留存：D1-D7/D1-D14至少再发1篇有效公开笔记；未成熟为NULL
-- 输出：新人一行，供归属诊断、实验前置和样本检查
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dws_new_creator_retention_detail_df (
    snapshot_date                    DATE,
    creator_id                       STRING,
    cohort_month                     STRING,
    primary_category                 STRING,
    support_group                    STRING,
    first_note_at                    TIMESTAMP,
    first_note_category              STRING,
    first_note_exposure_uv           BIGINT,
    first_note_click_uv              BIGINT,
    first_note_ctr                   DECIMAL(18,10),
    first_note_interaction_rate      DECIMAL(18,10),
    first_note_product_click_rate    DECIMAL(18,10),
    first_note_conversion_flag       INT,
    first_note_exposure_quintile     INT,
    first_note_exposure_band         STRING,
    first_note_interaction_quintile  INT,
    first_note_interaction_band      STRING,
    first_note_segment               STRING,
    retained_7d                      INT,
    retained_7d_eligible             INT,
    retained_14d                     INT,
    retained_14d_eligible            INT,
    churn_28d                        INT,
    churn_label_eligible             INT,
    quality_level                    STRING,
    metric_version                   STRING
)
PARTITIONED BY (dt STRING)
STORED AS PARQUET;

WITH new_creator AS (
    SELECT *
    FROM dws_creator_lifecycle_df
    WHERE dt = '${hivevar:biz_date}'
      AND is_new_creator = 1
),
note_ranked AS (
    SELECT
        n.*,
        ROW_NUMBER() OVER (
            PARTITION BY n.creator_id
            ORDER BY n.publish_time, n.note_id
        ) AS first_note_rn
    FROM dwd_note_behavior_df n
    JOIN new_creator c
      ON n.creator_id = c.creator_id
    WHERE n.dt = '${hivevar:biz_date}'
      AND n.is_core_eligible = 1
      AND n.publish_time >= '${hivevar:feature_start} 00:00:00'
      AND n.publish_time <= CAST('${hivevar:data_extract_date} 23:59:59' AS TIMESTAMP)
),
first_note AS (
    SELECT
        n.creator_id,
        n.publish_time AS first_note_at,
        n.content_category AS first_note_category,
        COALESCE(n.exposure_uv_7d, 0) AS first_note_exposure_uv,
        COALESCE(n.click_uv_7d, 0) AS first_note_click_uv,
        CASE
            WHEN COALESCE(n.exposure_uv_7d, 0) = 0 THEN CAST(NULL AS DECIMAL(18,10))
            ELSE CAST(n.click_uv_7d AS DECIMAL(18,10)) / CAST(n.exposure_uv_7d AS DECIMAL(18,10))
        END AS first_note_ctr,
        CASE
            WHEN COALESCE(n.click_uv_7d, 0) = 0 THEN CAST(NULL AS DECIMAL(18,10))
            ELSE CAST(n.interaction_cnt_7d AS DECIMAL(18,10)) / CAST(n.click_uv_7d AS DECIMAL(18,10))
        END AS first_note_interaction_rate,
        CASE
            WHEN COALESCE(n.click_uv_7d, 0) = 0 THEN CAST(NULL AS DECIMAL(18,10))
            ELSE CAST(n.product_click_uv_30d AS DECIMAL(18,10)) / CAST(n.click_uv_7d AS DECIMAL(18,10))
        END AS first_note_product_click_rate,
        CASE WHEN COALESCE(n.paid_buyer_uv_30d, 0) > 0 THEN 1 ELSE 0 END AS first_note_conversion_flag
    FROM note_ranked n
    WHERE n.first_note_rn = 1
),
segmented AS (
    SELECT
        f.*,
        NTILE(5) OVER (
            PARTITION BY c.cohort_month, f.first_note_category
            ORDER BY f.first_note_exposure_uv, f.creator_id
        ) AS exposure_quintile,
        NTILE(5) OVER (
            PARTITION BY c.cohort_month, f.first_note_category
            ORDER BY COALESCE(f.first_note_interaction_rate, 0), f.creator_id
        ) AS interaction_quintile
    FROM first_note f
    JOIN new_creator c
      ON f.creator_id = c.creator_id
)
INSERT OVERWRITE TABLE dws_new_creator_retention_detail_df PARTITION (dt='${hivevar:biz_date}')
SELECT
    c.snapshot_date,
    c.creator_id,
    c.cohort_month,
    c.primary_category,
    c.support_group,
    s.first_note_at,
    s.first_note_category,
    s.first_note_exposure_uv,
    s.first_note_click_uv,
    s.first_note_ctr,
    s.first_note_interaction_rate,
    s.first_note_product_click_rate,
    s.first_note_conversion_flag,
    s.exposure_quintile,
    CASE WHEN s.exposure_quintile <= 2 THEN '低曝光'
         WHEN s.exposure_quintile = 3 THEN '中曝光'
         ELSE '高曝光' END AS first_note_exposure_band,
    s.interaction_quintile,
    CASE WHEN s.interaction_quintile <= 2 THEN '低互动'
         WHEN s.interaction_quintile = 3 THEN '中互动'
         ELSE '高互动' END AS first_note_interaction_band,
    CONCAT(
        CASE WHEN s.exposure_quintile <= 2 THEN '低曝光'
             WHEN s.exposure_quintile = 3 THEN '中曝光'
             ELSE '高曝光' END,
        '/',
        CASE WHEN s.interaction_quintile <= 2 THEN '低互动'
             WHEN s.interaction_quintile = 3 THEN '中互动'
             ELSE '高互动' END
    ) AS first_note_segment,
    c.retained_7d,
    c.retained_7d_eligible,
    c.retained_14d,
    c.retained_14d_eligible,
    c.churn_28d,
    c.churn_label_eligible,
    c.quality_level,
    '${hivevar:metric_version}' AS metric_version
FROM segmented s
JOIN new_creator c
  ON s.creator_id = c.creator_id;

-- ----------------------------------------------------------------------------
-- 分层：DWS
-- 业务口径：按首月×首篇类目×首篇表现分群汇总新人留存
-- 统计窗口：首篇后D1-D7、D1-D14；未成熟样本不进分母
-- 输出：分组人数、成熟人数、留存人数和留存率
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dws_new_creator_retention_df (
    snapshot_date                 DATE,
    cohort_month                  STRING,
    content_category              STRING,
    first_note_segment            STRING,
    creator_cnt                   BIGINT,
    retention_7d_eligible_cnt     BIGINT,
    retained_7d_cnt               BIGINT,
    retention_7d_rate             DECIMAL(12,8),
    retention_14d_eligible_cnt    BIGINT,
    retained_14d_cnt              BIGINT,
    retention_14d_rate            DECIMAL(12,8),
    churn_eligible_cnt            BIGINT,
    churn_cnt                     BIGINT,
    churn_28d_rate                DECIMAL(12,8),
    avg_first_note_exposure_uv    DECIMAL(18,4),
    avg_first_note_ctr            DECIMAL(18,10),
    avg_first_note_interaction_rate DECIMAL(18,10),
    metric_version                STRING
)
PARTITIONED BY (dt STRING)
STORED AS PARQUET;

INSERT OVERWRITE TABLE dws_new_creator_retention_df PARTITION (dt='${hivevar:biz_date}')
SELECT
    snapshot_date,
    cohort_month,
    first_note_category AS content_category,
    first_note_segment,
    COUNT(*) AS creator_cnt,
    SUM(retained_7d_eligible) AS retention_7d_eligible_cnt,
    SUM(COALESCE(retained_7d, 0)) AS retained_7d_cnt,
    CASE
        WHEN SUM(retained_7d_eligible) = 0 THEN NULL
        ELSE CAST(SUM(COALESCE(retained_7d, 0)) AS DECIMAL(18,8))
             / CAST(SUM(retained_7d_eligible) AS DECIMAL(18,8))
    END AS retention_7d_rate,
    SUM(retained_14d_eligible) AS retention_14d_eligible_cnt,
    SUM(COALESCE(retained_14d, 0)) AS retained_14d_cnt,
    CASE
        WHEN SUM(retained_14d_eligible) = 0 THEN NULL
        ELSE CAST(SUM(COALESCE(retained_14d, 0)) AS DECIMAL(18,8))
             / CAST(SUM(retained_14d_eligible) AS DECIMAL(18,8))
    END AS retention_14d_rate,
    SUM(churn_label_eligible) AS churn_eligible_cnt,
    SUM(COALESCE(churn_28d, 0)) AS churn_cnt,
    CASE
        WHEN SUM(churn_label_eligible) = 0 THEN NULL
        ELSE CAST(SUM(COALESCE(churn_28d, 0)) AS DECIMAL(18,8))
             / CAST(SUM(churn_label_eligible) AS DECIMAL(18,8))
    END AS churn_28d_rate,
    AVG(first_note_exposure_uv) AS avg_first_note_exposure_uv,
    AVG(first_note_ctr) AS avg_first_note_ctr,
    AVG(first_note_interaction_rate) AS avg_first_note_interaction_rate,
    '${hivevar:metric_version}' AS metric_version
FROM dws_new_creator_retention_detail_df
WHERE dt = '${hivevar:biz_date}'
GROUP BY snapshot_date, cohort_month, first_note_category, first_note_segment;

-- ----------------------------------------------------------------------------
-- 分层：DWS
-- 业务口径：内容赛道横向比较
-- 活跃：赛道内特征窗至少1篇有效公开笔记
-- 流量分配：赛道曝光UV/平台总曝光UV；变现率用达人维度去重
-- 留存：新人首篇归入赛道，按成熟样本计算D7/D14
-- 输出：各赛道规模、流量、互动、转化、收益和留存
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dws_track_performance_df (
    snapshot_date                  DATE,
    content_category               STRING,
    is_rankable                    INT,
    active_creator_cnt             BIGINT,
    new_creator_cnt                BIGINT,
    head_creator_cnt               BIGINT,
    waist_creator_cnt              BIGINT,
    tail_creator_cnt               BIGINT,
    valid_note_cnt                 BIGINT,
    exposure_uv_7d                 BIGINT,
    click_uv_7d                    BIGINT,
    positive_interaction_cnt       BIGINT,
    ctr                            DECIMAL(18,10),
    positive_interaction_rate      DECIMAL(18,10),
    product_click_uv_30d           BIGINT,
    paid_buyer_uv_30d              BIGINT,
    commerce_conversion_rate       DECIMAL(18,10),
    net_gmv_30d                    DECIMAL(18,2),
    ad_revenue_30d                 DECIMAL(18,2),
    commission_revenue_30d         DECIMAL(18,2),
    settled_revenue_30d            DECIMAL(18,2),
    monetizing_creator_cnt         BIGINT,
    revenue_per_note               DECIMAL(18,4),
    revenue_per_1k_exposure        DECIMAL(18,8),
    negative_feedback_rate         DECIMAL(18,10),
    retention_7d_eligible_cnt      BIGINT,
    retained_7d_cnt                BIGINT,
    retention_7d_rate              DECIMAL(12,8),
    retention_14d_eligible_cnt     BIGINT,
    retained_14d_cnt               BIGINT,
    retention_14d_rate             DECIMAL(12,8),
    traffic_share                  DECIMAL(12,8),
    revenue_share                  DECIMAL(12,8),
    metric_version                 STRING
)
PARTITIONED BY (dt STRING)
STORED AS PARQUET;

WITH track_note AS (
    SELECT
        n.snapshot_date,
        n.content_category,
        n.creator_id,
        n.creator_tier,
        n.note_id,
        n.exposure_uv_7d,
        n.click_uv_7d,
        n.positive_interaction_cnt,
        n.product_click_uv_30d,
        n.paid_buyer_uv_30d,
        n.net_gmv_30d,
        n.ad_revenue_30d,
        n.commission_revenue_30d,
        n.settled_revenue_30d,
        n.negative_feedback_rate
    FROM dws_note_traffic_conversion_df n
    WHERE n.dt = '${hivevar:biz_date}'
),
new_retention_by_track AS (
    SELECT
        first_note_category AS content_category,
        SUM(retention_7d_eligible) AS retention_7d_eligible_cnt,
        SUM(COALESCE(retained_7d, 0)) AS retained_7d_cnt,
        SUM(retention_14d_eligible) AS retention_14d_eligible_cnt,
        SUM(COALESCE(retained_14d, 0)) AS retained_14d_cnt
    FROM dws_new_creator_retention_detail_df
    WHERE dt = '${hivevar:biz_date}'
    GROUP BY first_note_category
),
track_base AS (
    SELECT
        snapshot_date,
        content_category,
        COUNT(DISTINCT creator_id) AS active_creator_cnt,
        COUNT(DISTINCT CASE WHEN creator_tier = '新人' THEN creator_id END) AS new_creator_cnt,
        COUNT(DISTINCT CASE WHEN creator_tier = '头部' THEN creator_id END) AS head_creator_cnt,
        COUNT(DISTINCT CASE WHEN creator_tier = '腰部' THEN creator_id END) AS waist_creator_cnt,
        COUNT(DISTINCT CASE WHEN creator_tier = '尾部' THEN creator_id END) AS tail_creator_cnt,
        COUNT(note_id) AS valid_note_cnt,
        SUM(exposure_uv_7d) AS exposure_uv_7d,
        SUM(click_uv_7d) AS click_uv_7d,
        SUM(positive_interaction_cnt) AS positive_interaction_cnt,
        SUM(product_click_uv_30d) AS product_click_uv_30d,
        SUM(paid_buyer_uv_30d) AS paid_buyer_uv_30d,
        SUM(net_gmv_30d) AS net_gmv_30d,
        SUM(ad_revenue_30d) AS ad_revenue_30d,
        SUM(commission_revenue_30d) AS commission_revenue_30d,
        SUM(settled_revenue_30d) AS settled_revenue_30d,
        COUNT(DISTINCT CASE WHEN settled_revenue_30d > 0 THEN creator_id END) AS monetizing_creator_cnt,
        SUM(COALESCE(negative_feedback_rate, 0) * COALESCE(exposure_uv_7d, 0))
          / GREATEST(SUM(exposure_uv_7d), 1) AS negative_feedback_rate
    FROM track_note
    GROUP BY snapshot_date, content_category
),
track_joined AS (
    SELECT
        b.*,
        COALESCE(r.retention_7d_eligible_cnt, 0) AS retention_7d_eligible_cnt,
        COALESCE(r.retained_7d_cnt, 0) AS retained_7d_cnt,
        COALESCE(r.retention_14d_eligible_cnt, 0) AS retention_14d_eligible_cnt,
        COALESCE(r.retained_14d_cnt, 0) AS retained_14d_cnt,
        SUM(b.exposure_uv_7d) OVER (PARTITION BY b.snapshot_date) AS total_exposure,
        SUM(b.settled_revenue_30d) OVER (PARTITION BY b.snapshot_date) AS total_revenue
    FROM track_base b
    LEFT JOIN new_retention_by_track r
      ON b.content_category = r.content_category
)
INSERT OVERWRITE TABLE dws_track_performance_df PARTITION (dt='${hivevar:biz_date}')
SELECT
    snapshot_date,
    content_category,
    CASE WHEN content_category = '未分类' THEN 0 ELSE 1 END AS is_rankable,
    active_creator_cnt,
    new_creator_cnt,
    head_creator_cnt,
    waist_creator_cnt,
    tail_creator_cnt,
    valid_note_cnt,
    exposure_uv_7d,
    click_uv_7d,
    positive_interaction_cnt,
    CASE WHEN exposure_uv_7d = 0 THEN NULL
         ELSE CAST(click_uv_7d AS DECIMAL(18,10)) / CAST(exposure_uv_7d AS DECIMAL(18,10)) END AS ctr,
    CASE WHEN click_uv_7d = 0 THEN NULL
         ELSE CAST(positive_interaction_cnt AS DECIMAL(18,10)) / CAST(click_uv_7d AS DECIMAL(18,10)) END AS positive_interaction_rate,
    product_click_uv_30d,
    paid_buyer_uv_30d,
    CASE WHEN product_click_uv_30d = 0 THEN NULL
         ELSE CAST(paid_buyer_uv_30d AS DECIMAL(18,10)) / CAST(product_click_uv_30d AS DECIMAL(18,10)) END AS commerce_conversion_rate,
    net_gmv_30d,
    ad_revenue_30d,
    commission_revenue_30d,
    settled_revenue_30d,
    monetizing_creator_cnt,
    CASE WHEN valid_note_cnt = 0 THEN NULL
         ELSE CAST(settled_revenue_30d AS DECIMAL(18,4)) / CAST(valid_note_cnt AS DECIMAL(18,4)) END AS revenue_per_note,
    CASE WHEN exposure_uv_7d = 0 THEN NULL
         ELSE CAST(settled_revenue_30d AS DECIMAL(18,8)) * 1000 / CAST(exposure_uv_7d AS DECIMAL(18,8)) END AS revenue_per_1k_exposure,
    negative_feedback_rate,
    retention_7d_eligible_cnt,
    retained_7d_cnt,
    CASE WHEN retention_7d_eligible_cnt = 0 THEN NULL
         ELSE CAST(retained_7d_cnt AS DECIMAL(18,8)) / CAST(retention_7d_eligible_cnt AS DECIMAL(18,8)) END AS retention_7d_rate,
    retention_14d_eligible_cnt,
    retained_14d_cnt,
    CASE WHEN retention_14d_eligible_cnt = 0 THEN NULL
         ELSE CAST(retained_14d_cnt AS DECIMAL(18,8)) / CAST(retention_14d_eligible_cnt AS DECIMAL(18,8)) END AS retention_14d_rate,
    CASE WHEN total_exposure = 0 THEN NULL
         ELSE CAST(exposure_uv_7d AS DECIMAL(18,8)) / CAST(total_exposure AS DECIMAL(18,8)) END AS traffic_share,
    CASE WHEN total_revenue = 0 THEN NULL
         ELSE CAST(settled_revenue_30d AS DECIMAL(18,8)) / CAST(total_revenue AS DECIMAL(18,8)) END AS revenue_share,
    '${hivevar:metric_version}' AS metric_version
FROM track_joined;
