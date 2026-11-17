-- ============================================================================
-- 内容社区 APP 创作者成长与变现归因
-- 分层：ODS -> DWD
-- 业务口径：有效公开笔记、测试/内部/作弊排除、重复上报去重、7/30 日窗口
-- 统计窗口：特征 2025-09-01~2026-01-31；标签 2026-02-01~2026-02-28
-- 输出：DWD 创作者画像、DWD 笔记行为、账号治理控制维表
-- 说明：ODS 不改写；DWD 保留全部去重后记录并打质量标记
-- ============================================================================

SET hivevar:biz_date=2026-02-28;
SET hivevar:feature_start=2025-09-01;
SET hivevar:feature_end=2026-01-31;
SET hivevar:label_start=2026-02-01;
SET hivevar:label_end=2026-02-28;
SET hivevar:data_extract_date=2026-03-31;
SET hivevar:metric_version=dws_v1.0;

-- ----------------------------------------------------------------------------
-- 分层：控制维表
-- 业务口径：账号治理状态，只作为 DWD 过滤的控制条件，不进入业务指标
-- 统计窗口：有效期内
-- 输出字段：creator_id、risk_type、risk_level、manual_flag
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dim_account_risk_df (
    creator_id       STRING COMMENT '创作者ID',
    risk_type        STRING COMMENT 'test/internal/cheat_confirmed/other',
    risk_level       DECIMAL(5,4) COMMENT '风险分0-1',
    manual_flag      INT COMMENT '人工确认1/0',
    valid_from       DATE COMMENT '生效日',
    valid_to         DATE COMMENT '失效日，空表示长期有效',
    source_system    STRING COMMENT '风控、QA或账号治理系统'
)
STORED AS PARQUET;

-- ----------------------------------------------------------------------------
-- 分层：DWD
-- 业务口径：先对 ODS 笔记快照按 note_id 去重，再做合法性、链路和值域判断
-- 统计窗口：ODS 全分区；DWD 固定写入 biz_date 分区
-- 输出：全部去重笔记 + 硬过滤/软异常/完整度标记
-- 注意：若 ODS 实际是逐事件明细，应先按 user_id+note_id+event_date 聚合
--       UV 后再进入本快照逻辑；不能直接把事件行当笔记行相加。
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dwd_note_base_df (
    source_dt                   STRING COMMENT '原始装载分区',
    note_id                     STRING COMMENT '笔记ID',
    creator_id                  STRING COMMENT '创作者ID',
    publish_time                TIMESTAMP COMMENT '公开发布时间',
    content_type                STRING COMMENT '内容形态',
    content_category            STRING COMMENT '内容类目',
    topic_tag                   STRING COMMENT '话题标签',
    title_length                INT COMMENT '标题长度',
    body_length                 INT COMMENT '正文长度',
    image_cnt                   INT COMMENT '图片数',
    content_quality_score       DECIMAL(8,4) COMMENT '内容质量分',
    has_product_link            INT COMMENT '是否挂商品链接',
    product_category            STRING COMMENT '商品类目',
    is_commercial_content       INT COMMENT '商业内容标记',
    distribution_pool           STRING COMMENT '流量池',
    algorithm_version           STRING COMMENT '算法版本',
    platform_activity_id        STRING COMMENT '活动ID',
    source_note_status          STRING COMMENT '原始笔记状态',
    note_status                 STRING COMMENT '标准化笔记状态',
    traffic_window_end_date     DATE COMMENT '7日流量窗结束日',
    commerce_window_end_date    DATE COMMENT '30日成交窗结束日',
    exposure_pv_7d              BIGINT COMMENT '7日曝光PV',
    exposure_uv_7d              BIGINT COMMENT '7日曝光UV',
    click_pv_7d                 BIGINT COMMENT '7日点击PV',
    click_uv_7d                 BIGINT COMMENT '7日点击UV',
    avg_read_seconds_7d         DECIMAL(12,4) COMMENT '平均阅读秒数',
    completion_rate_7d          DECIMAL(12,8) COMMENT '完读率',
    like_cnt_7d                 BIGINT COMMENT '点赞数',
    comment_cnt_7d              BIGINT COMMENT '评论数',
    favorite_cnt_7d             BIGINT COMMENT '收藏数',
    share_cnt_7d                BIGINT COMMENT '分享数',
    interaction_cnt_7d          BIGINT COMMENT '互动总量',
    negative_feedback_cnt_7d    BIGINT COMMENT '负反馈量',
    follow_cnt_7d               BIGINT COMMENT '新增关注量',
    product_click_uv_30d        BIGINT COMMENT '30日商品点击UV',
    paid_order_cnt_30d          BIGINT COMMENT '30日支付订单数',
    paid_buyer_uv_30d           BIGINT COMMENT '30日付费买家UV',
    gross_gmv_30d               DECIMAL(18,2) COMMENT '30日成交GMV',
    refund_gmv_30d              DECIMAL(18,2) COMMENT '30日退款GMV',
    net_gmv_30d                 DECIMAL(18,2) COMMENT '30日净GMV',
    ad_revenue_30d              DECIMAL(18,2) COMMENT '已结算广告分成',
    commission_revenue_30d      DECIMAL(18,2) COMMENT '已结算佣金',
    settlement_status           STRING COMMENT '结算状态',
    data_version                STRING COMMENT '源数据版本',
    interaction_sum_calc        BIGINT COMMENT '四类互动重算值',
    metric_window_complete      INT COMMENT '核心指标窗口完整1/0',
    is_hard_invalid             INT COMMENT '硬过滤1/0',
    hard_invalid_reason         STRING COMMENT '硬过滤原因',
    is_soft_anomaly             INT COMMENT '软异常1/0',
    soft_anomaly_reason         STRING COMMENT '软异常原因',
    is_behavior_risk_note       INT COMMENT '互动或关注异常笔记1/0',
    is_base_eligible            INT COMMENT '通过笔记级硬校验1/0',
    quality_level               STRING COMMENT '高/中/低',
    metric_version              STRING COMMENT '指标口径版本'
)
PARTITIONED BY (dt STRING COMMENT '数据快照日')
STORED AS PARQUET;

WITH note_ranked AS (
    SELECT
        n.*,
        ROW_NUMBER() OVER (
            PARTITION BY n.note_id
            ORDER BY
                     CASE
                         WHEN n.traffic_window_end_date <= '${hivevar:data_extract_date}'
                          AND n.commerce_window_end_date <= '${hivevar:data_extract_date}' THEN 0
                         ELSE 1
                     END,
                     n.dt DESC, COALESCE(n.etl_time, CAST('1970-01-01 00:00:00' AS TIMESTAMP)) DESC,
                     n.data_version DESC
        ) AS rn
    FROM ods_note_behavior n
    WHERE n.dt BETWEEN '${hivevar:feature_start}' AND '${hivevar:data_extract_date}'
),
-- 阈值说明：相对倍数和绝对量同时满足才判软异常；生产维护时可按前180天
-- 同赛道/内容形态/算法版本的 P99.5 校准，当前值是可审计的基线配置。
note_enriched AS (
    SELECT
        n.*,
        CASE
            WHEN n.note_status = '公开' THEN '公开'
            WHEN n.note_status IN ('撤回','取消') THEN '撤回或取消'
            ELSE COALESCE(n.note_status, '未知状态')
        END AS normalized_note_status,
        COALESCE(n.like_cnt_7d, 0)
          + COALESCE(n.comment_cnt_7d, 0)
          + COALESCE(n.favorite_cnt_7d, 0)
          + COALESCE(n.share_cnt_7d, 0) AS interaction_sum_calc,
        CASE
            WHEN n.note_status = '公开'
             AND n.traffic_window_end_date IS NOT NULL
             AND n.commerce_window_end_date IS NOT NULL
             AND n.traffic_window_end_date <= '${hivevar:data_extract_date}'
             AND n.commerce_window_end_date <= '${hivevar:data_extract_date}'
             AND n.exposure_uv_7d IS NOT NULL
             AND n.click_uv_7d IS NOT NULL
             AND n.interaction_cnt_7d IS NOT NULL
             AND n.paid_buyer_uv_30d IS NOT NULL
             AND n.product_click_uv_30d IS NOT NULL
            THEN 1 ELSE 0
        END AS metric_window_complete,
        CASE
            WHEN n.note_id IS NULL OR n.creator_id IS NULL THEN 1
            WHEN n.publish_time IS NULL
              OR n.publish_time > CAST('${hivevar:data_extract_date} 23:59:59' AS TIMESTAMP) THEN 1
            WHEN n.note_status IS NULL OR n.note_status <> '公开' THEN 1
            WHEN n.click_uv_7d > n.exposure_uv_7d THEN 1
            WHEN n.click_pv_7d > n.exposure_pv_7d THEN 1
            WHEN n.click_pv_7d < n.click_uv_7d THEN 1
            WHEN n.exposure_pv_7d < n.exposure_uv_7d THEN 1
            WHEN n.completion_rate_7d < 0 OR n.completion_rate_7d > 1 THEN 1
            WHEN COALESCE(n.exposure_uv_7d, 0) = 0
             AND (COALESCE(n.ad_revenue_30d, 0) > 10 OR COALESCE(n.commission_revenue_30d, 0) > 50) THEN 1
            WHEN COALESCE(n.paid_buyer_uv_30d, 0) > COALESCE(n.product_click_uv_30d, 0) THEN 1
            WHEN COALESCE(n.product_click_uv_30d, 0) > 0 AND COALESCE(n.has_product_link, 0) = 0 THEN 1
            WHEN COALESCE(n.gross_gmv_30d, 0) > 0 AND COALESCE(n.has_product_link, 0) = 0 THEN 1
            WHEN COALESCE(n.refund_gmv_30d, 0) > COALESCE(n.gross_gmv_30d, 0) THEN 1
            WHEN n.interaction_cnt_7d
                 <> COALESCE(n.like_cnt_7d, 0) + COALESCE(n.comment_cnt_7d, 0)
                    + COALESCE(n.favorite_cnt_7d, 0) + COALESCE(n.share_cnt_7d, 0) THEN 1
            WHEN COALESCE(n.exposure_uv_7d, 0) < 0 OR COALESCE(n.click_uv_7d, 0) < 0
              OR COALESCE(n.interaction_cnt_7d, 0) < 0 OR COALESCE(n.paid_order_cnt_30d, 0) < 0
              OR COALESCE(n.gross_gmv_30d, 0) < 0 OR COALESCE(n.refund_gmv_30d, 0) < 0
              OR COALESCE(n.ad_revenue_30d, 0) < 0 OR COALESCE(n.commission_revenue_30d, 0) < 0 THEN 1
            ELSE 0
        END AS is_hard_invalid,
        CASE
            WHEN n.interaction_cnt_7d > 12 * GREATEST(COALESCE(n.click_uv_7d, 0), 1)
             AND n.interaction_cnt_7d >= 1000 THEN 1
            WHEN n.follow_cnt_7d > 0.2 * GREATEST(COALESCE(n.click_uv_7d, 0), 1)
             AND n.follow_cnt_7d >= 500 THEN 1
            ELSE 0
        END AS is_behavior_risk_note,
        CASE
            WHEN n.interaction_cnt_7d > 12 * GREATEST(COALESCE(n.click_uv_7d, 0), 1)
             AND n.interaction_cnt_7d >= 1000 THEN 1
            WHEN n.follow_cnt_7d > 0.2 * GREATEST(COALESCE(n.click_uv_7d, 0), 1)
             AND n.follow_cnt_7d >= 500 THEN 1
            WHEN n.avg_read_seconds_7d > 3600 THEN 1
            WHEN n.negative_feedback_cnt_7d > 0.05 * GREATEST(COALESCE(n.exposure_pv_7d, 0), 1) THEN 1
            WHEN COALESCE(n.exposure_uv_7d, 0) = 0
             AND (COALESCE(n.ad_revenue_30d, 0) > 0 OR COALESCE(n.commission_revenue_30d, 0) > 0) THEN 1
            ELSE 0
        END AS is_soft_anomaly,
        CASE
            WHEN n.interaction_cnt_7d > 12 * GREATEST(COALESCE(n.click_uv_7d, 0), 1)
             AND n.interaction_cnt_7d >= 1000 THEN 'INTERACTION_ABOVE_12X_AND_1000'
            WHEN n.follow_cnt_7d > 0.2 * GREATEST(COALESCE(n.click_uv_7d, 0), 1)
             AND n.follow_cnt_7d >= 500 THEN 'FOLLOW_RATE_ABOVE_20PCT'
            WHEN n.avg_read_seconds_7d > 3600 THEN 'READ_TIME_ABOVE_1H'
            WHEN n.negative_feedback_cnt_7d > 0.05 * GREATEST(COALESCE(n.exposure_pv_7d, 0), 1) THEN 'NEGATIVE_FEEDBACK_ABOVE_5PCT'
            ELSE NULL
        END AS soft_anomaly_reason
    FROM note_ranked n
    WHERE n.rn = 1
),
note_flags AS (
    SELECT
        n.*,
        CASE
            WHEN n.note_id IS NULL OR n.creator_id IS NULL THEN 'S01_NULL_KEY'
            WHEN n.publish_time IS NULL
              OR n.publish_time > CAST('${hivevar:data_extract_date} 23:59:59' AS TIMESTAMP) THEN 'S06_INVALID_PUBLISH_TIME'
            WHEN n.note_status IS NULL OR n.note_status <> '公开' THEN 'S05_NOTE_NOT_PUBLIC'
            WHEN n.click_uv_7d > n.exposure_uv_7d OR n.click_pv_7d > n.exposure_pv_7d
              OR n.click_pv_7d < n.click_uv_7d OR n.exposure_pv_7d < n.exposure_uv_7d THEN 'S08_FUNNEL_LOGIC_ERROR'
            WHEN COALESCE(n.exposure_uv_7d, 0) = 0
             AND (COALESCE(n.ad_revenue_30d, 0) > 10 OR COALESCE(n.commission_revenue_30d, 0) > 50) THEN 'S07_ZERO_EXPOSURE_REVENUE'
            WHEN COALESCE(n.paid_buyer_uv_30d, 0) > COALESCE(n.product_click_uv_30d, 0)
              OR (COALESCE(n.product_click_uv_30d, 0) > 0 AND COALESCE(n.has_product_link, 0) = 0)
              OR (COALESCE(n.gross_gmv_30d, 0) > 0 AND COALESCE(n.has_product_link, 0) = 0)
              OR COALESCE(n.refund_gmv_30d, 0) > COALESCE(n.gross_gmv_30d, 0) THEN 'S09_COMMERCE_LOGIC_ERROR'
            WHEN n.completion_rate_7d < 0 OR n.completion_rate_7d > 1 THEN 'S15_INVALID_RATE_RANGE'
            WHEN n.interaction_cnt_7d
                 <> COALESCE(n.like_cnt_7d, 0) + COALESCE(n.comment_cnt_7d, 0)
                    + COALESCE(n.favorite_cnt_7d, 0) + COALESCE(n.share_cnt_7d, 0) THEN 'S10_INTERACTION_RECON_ERROR'
            WHEN COALESCE(n.exposure_uv_7d, 0) < 0 OR COALESCE(n.click_uv_7d, 0) < 0
              OR COALESCE(n.interaction_cnt_7d, 0) < 0 OR COALESCE(n.paid_order_cnt_30d, 0) < 0
              OR COALESCE(n.gross_gmv_30d, 0) < 0 OR COALESCE(n.refund_gmv_30d, 0) < 0
              OR COALESCE(n.ad_revenue_30d, 0) < 0 OR COALESCE(n.commission_revenue_30d, 0) < 0 THEN 'S16_NEGATIVE_METRIC'
            ELSE NULL
        END AS hard_invalid_reason
    FROM note_enriched n
)
INSERT OVERWRITE TABLE dwd_note_base_df PARTITION (dt='${hivevar:biz_date}')
SELECT
    CAST(n.dt AS STRING) AS source_dt,
    n.note_id,
    n.creator_id,
    n.publish_time,
    n.content_type,
    COALESCE(n.content_category, '未分类') AS content_category,
    n.topic_tag,
    n.title_length,
    n.body_length,
    n.image_cnt,
    n.content_quality_score,
    n.has_product_link,
    CASE
        WHEN n.has_product_link = 1 AND n.product_category IS NULL THEN '商品类目未知'
        ELSE n.product_category
    END AS product_category,
    n.is_commercial_content,
    n.distribution_pool,
    n.algorithm_version,
    n.platform_activity_id,
    n.note_status AS source_note_status,
    n.normalized_note_status AS note_status,
    n.traffic_window_end_date,
    n.commerce_window_end_date,
    n.exposure_pv_7d,
    n.exposure_uv_7d,
    n.click_pv_7d,
    n.click_uv_7d,
    n.avg_read_seconds_7d,
    n.completion_rate_7d,
    n.like_cnt_7d,
    n.comment_cnt_7d,
    n.favorite_cnt_7d,
    n.share_cnt_7d,
    n.interaction_cnt_7d,
    n.negative_feedback_cnt_7d,
    n.follow_cnt_7d,
    n.product_click_uv_30d,
    n.paid_order_cnt_30d,
    n.paid_buyer_uv_30d,
    n.gross_gmv_30d,
    n.refund_gmv_30d,
    n.net_gmv_30d,
    n.ad_revenue_30d,
    n.commission_revenue_30d,
    n.settlement_status,
    n.data_version,
    n.interaction_sum_calc,
    n.metric_window_complete,
    CASE WHEN n.hard_invalid_reason IS NULL THEN 0 ELSE 1 END AS is_hard_invalid,
    n.hard_invalid_reason,
    n.is_soft_anomaly,
    n.soft_anomaly_reason,
    n.is_behavior_risk_note,
    CASE
        WHEN n.hard_invalid_reason IS NULL AND n.metric_window_complete = 1 THEN 1
        ELSE 0
    END AS is_base_eligible,
    CASE
        WHEN n.hard_invalid_reason IS NOT NULL THEN '低'
        WHEN n.metric_window_complete = 0 OR n.is_soft_anomaly = 1 THEN '中'
        ELSE '高'
    END AS quality_level,
    '${hivevar:metric_version}' AS metric_version
FROM note_flags n;

-- ----------------------------------------------------------------------------
-- 分层：DWD
-- 业务口径：账号级行为异常汇总，供创作者维度判断可疑刷量
-- 统计窗口：DWD note_base 当前快照
-- 输出：每位创作者的异常笔记数与占比
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dwd_creator_note_risk_df (
    creator_id                    STRING,
    eligible_note_cnt             BIGINT,
    behavior_risk_note_cnt        BIGINT,
    behavior_risk_note_share      DECIMAL(12,8),
    soft_anomaly_note_cnt         BIGINT,
    hard_invalid_note_cnt         BIGINT,
    metric_version                STRING
)
PARTITIONED BY (dt STRING)
STORED AS PARQUET;

INSERT OVERWRITE TABLE dwd_creator_note_risk_df PARTITION (dt='${hivevar:biz_date}')
SELECT
    creator_id,
    COUNT(CASE WHEN is_hard_invalid = 0 THEN 1 END) AS eligible_note_cnt,
    SUM(COALESCE(is_behavior_risk_note, 0)) AS behavior_risk_note_cnt,
    CASE
        WHEN COUNT(CASE WHEN is_hard_invalid = 0 THEN 1 END) = 0 THEN CAST(0 AS DECIMAL(12,8))
        ELSE CAST(SUM(COALESCE(is_behavior_risk_note, 0)) AS DECIMAL(18,8))
             / CAST(COUNT(CASE WHEN is_hard_invalid = 0 THEN 1 END) AS DECIMAL(18,8))
    END AS behavior_risk_note_share,
    SUM(COALESCE(is_soft_anomaly, 0)) AS soft_anomaly_note_cnt,
    SUM(COALESCE(is_hard_invalid, 0)) AS hard_invalid_note_cnt,
    '${hivevar:metric_version}' AS metric_version
FROM dwd_note_base_df
WHERE dt = '${hivevar:biz_date}'
  AND creator_id IS NOT NULL
GROUP BY creator_id;

-- ----------------------------------------------------------------------------
-- 分层：DWD
-- 业务口径：创作者账号治理、首末有效发文和质量分级
-- 统计窗口：首末发文使用截至提取日的有效公开笔记；画像使用快照日
-- 输出：创作者维度可分析表和全部过滤原因
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dwd_creator_profile_df (
    creator_id                     STRING,
    user_id                        STRING,
    account_created_at             TIMESTAMP,
    creator_activated_at           TIMESTAMP,
    source_first_publish_at        TIMESTAMP,
    source_last_publish_at         TIMESTAMP,
    first_valid_publish_at         TIMESTAMP,
    last_valid_publish_at          TIMESTAMP,
    snapshot_date                   DATE,
    feature_cutoff_date             DATE,
    cohort_month                    STRING,
    creator_stage                   STRING,
    is_new_creator                  INT,
    acquisition_channel             STRING,
    device_os                       STRING,
    city_tier                       STRING,
    primary_category                STRING,
    creator_level                   INT,
    verification_type               STRING,
    support_group                   STRING,
    assignment_method               STRING,
    baseline_fan_cnt                BIGINT,
    first_7d_publish_cnt            INT,
    first_7d_exposure_uv            BIGINT,
    first_7d_click_uv               BIGINT,
    first_7d_interaction_cnt        BIGINT,
    period_publish_cnt              INT,
    period_active_days              INT,
    period_exposure_uv              BIGINT,
    period_click_uv                 BIGINT,
    period_interaction_cnt          BIGINT,
    period_ad_revenue               DECIMAL(18,2),
    period_commission_revenue       DECIMAL(18,2),
    first_monetization_at           TIMESTAMP,
    monetization_status             STRING,
    source_churn_label_eligible     INT,
    churn_28d                       INT,
    churn_date                      DATE,
    account_status                  STRING,
    source_data_version             STRING,
    eligible_note_cnt               BIGINT,
    behavior_risk_note_cnt          BIGINT,
    behavior_risk_note_share        DECIMAL(12,8),
    account_risk_type               STRING,
    account_risk_level              DECIMAL(5,4),
    is_test_account                 INT,
    is_internal_account             INT,
    confirmed_cheat_flag            INT,
    suspected_cheat_flag            INT,
    category_missing_flag           INT,
    baseline_fan_missing_flag       INT,
    time_inconsistency_flag         INT,
    is_valid                        INT,
    is_core_eligible                INT,
    exclude_reason                  STRING,
    soft_anomaly_reason             STRING,
    quality_level                   STRING,
    metric_version                  STRING
)
PARTITIONED BY (dt STRING)
STORED AS PARQUET;

WITH creator_ranked AS (
    SELECT
        c.*,
        ROW_NUMBER() OVER (
            PARTITION BY c.creator_id
            ORDER BY c.dt DESC, COALESCE(c.etl_time, CAST('1970-01-01 00:00:00' AS TIMESTAMP)) DESC,
                     c.data_version DESC
        ) AS rn
    FROM ods_creator_profile c
    WHERE c.dt BETWEEN '${hivevar:feature_start}' AND '${hivevar:data_extract_date}'
),
risk_ranked AS (
    SELECT
        r.*,
        ROW_NUMBER() OVER (
            PARTITION BY r.creator_id
            ORDER BY r.risk_level DESC, r.valid_from DESC
        ) AS rn
    FROM dim_account_risk_df r
    WHERE r.valid_from <= '${hivevar:biz_date}'
      AND (r.valid_to IS NULL OR r.valid_to >= '${hivevar:biz_date}')
),
valid_note_agg AS (
    SELECT
        creator_id,
        MIN(publish_time) AS first_valid_publish_at,
        MAX(publish_time) AS last_valid_publish_at
    FROM dwd_note_base_df
    WHERE dt = '${hivevar:biz_date}'
      AND is_hard_invalid = 0
      AND note_status = '公开'
    GROUP BY creator_id
),
creator_base AS (
    SELECT
        c.creator_id,
        c.user_id,
        c.account_created_at,
        c.creator_activated_at,
        c.first_publish_at AS source_first_publish_at,
        c.last_publish_at AS source_last_publish_at,
        v.first_valid_publish_at,
        v.last_valid_publish_at,
        c.snapshot_date,
        c.feature_cutoff_date,
        c.cohort_month,
        c.creator_stage,
        c.is_new_creator,
        c.acquisition_channel,
        c.device_os,
        c.city_tier,
        COALESCE(c.primary_category, '未分类') AS primary_category,
        c.creator_level,
        c.verification_type,
        CASE
            WHEN c.is_new_creator = 1 AND c.support_group IS NULL THEN '未知扶持'
            WHEN c.is_new_creator = 0 AND c.support_group IS NULL THEN '无扶持'
            ELSE c.support_group
        END AS support_group,
        c.assignment_method,
        c.baseline_fan_cnt,
        c.first_7d_publish_cnt,
        c.first_7d_exposure_uv,
        c.first_7d_click_uv,
        c.first_7d_interaction_cnt,
        c.period_publish_cnt,
        c.period_active_days,
        c.period_exposure_uv,
        c.period_click_uv,
        c.period_interaction_cnt,
        c.period_ad_revenue,
        c.period_commission_revenue,
        c.first_monetization_at,
        c.monetization_status,
        c.churn_label_eligible AS source_churn_label_eligible,
        c.churn_28d,
        c.churn_date,
        c.account_status,
        c.data_version AS source_data_version,
        COALESCE(nr.eligible_note_cnt, 0) AS eligible_note_cnt,
        COALESCE(nr.behavior_risk_note_cnt, 0) AS behavior_risk_note_cnt,
        COALESCE(nr.behavior_risk_note_share, 0) AS behavior_risk_note_share,
        COALESCE(r.risk_type, 'none') AS account_risk_type,
        COALESCE(r.risk_level, 0) AS account_risk_level,
        CASE WHEN c.account_status = '测试' OR r.risk_type = 'test' THEN 1 ELSE 0 END AS is_test_account,
        CASE WHEN r.risk_type = 'internal' THEN 1 ELSE 0 END AS is_internal_account,
        CASE WHEN r.risk_type = 'cheat_confirmed' OR r.manual_flag = 1 THEN 1 ELSE 0 END AS confirmed_cheat_flag,
        CASE WHEN c.primary_category IS NULL THEN 1 ELSE 0 END AS category_missing_flag,
        CASE WHEN c.baseline_fan_cnt IS NULL THEN 1 ELSE 0 END AS baseline_fan_missing_flag,
        CASE
            WHEN c.first_publish_at IS NOT NULL AND c.last_publish_at IS NOT NULL
             AND c.first_publish_at > c.last_publish_at THEN 1
            ELSE 0
        END AS time_inconsistency_flag
    FROM creator_ranked c
    LEFT JOIN risk_ranked r
      ON c.creator_id = r.creator_id AND r.rn = 1
    LEFT JOIN dwd_creator_note_risk_df nr
      ON c.creator_id = nr.creator_id AND nr.dt = '${hivevar:biz_date}'
    LEFT JOIN valid_note_agg v
      ON c.creator_id = v.creator_id
    WHERE c.rn = 1
),
creator_flags AS (
    SELECT
        c.*,
        CASE
            WHEN c.creator_id IS NULL OR c.user_id IS NULL THEN 1
            WHEN c.is_test_account = 1 OR c.is_internal_account = 1 OR c.confirmed_cheat_flag = 1 THEN 1
            WHEN c.eligible_note_cnt = 0 OR c.first_valid_publish_at IS NULL THEN 1
            WHEN c.first_valid_publish_at > CAST('${hivevar:biz_date} 23:59:59' AS TIMESTAMP) THEN 1
            WHEN c.account_created_at IS NULL OR c.creator_activated_at IS NULL THEN 1
            ELSE 0
        END AS hard_invalid,
        CASE
            WHEN c.behavior_risk_note_cnt >= 2 AND c.behavior_risk_note_share >= 0.2 THEN 1
            WHEN c.behavior_risk_note_cnt >= 5 THEN 1
            ELSE 0
        END AS suspected_cheat_flag
    FROM creator_base c
)
INSERT OVERWRITE TABLE dwd_creator_profile_df PARTITION (dt='${hivevar:biz_date}')
SELECT
    c.creator_id,
    c.user_id,
    c.account_created_at,
    c.creator_activated_at,
    c.source_first_publish_at,
    c.source_last_publish_at,
    c.first_valid_publish_at,
    c.last_valid_publish_at,
    c.snapshot_date,
    c.feature_cutoff_date,
    c.cohort_month,
    c.creator_stage,
    c.is_new_creator,
    c.acquisition_channel,
    c.device_os,
    c.city_tier,
    c.primary_category,
    c.creator_level,
    c.verification_type,
    c.support_group,
    c.assignment_method,
    c.baseline_fan_cnt,
    c.first_7d_publish_cnt,
    c.first_7d_exposure_uv,
    c.first_7d_click_uv,
    c.first_7d_interaction_cnt,
    c.period_publish_cnt,
    c.period_active_days,
    c.period_exposure_uv,
    c.period_click_uv,
    c.period_interaction_cnt,
    c.period_ad_revenue,
    c.period_commission_revenue,
    c.first_monetization_at,
    c.monetization_status,
    c.source_churn_label_eligible,
    c.churn_28d,
    c.churn_date,
    c.account_status,
    c.source_data_version,
    c.eligible_note_cnt,
    c.behavior_risk_note_cnt,
    c.behavior_risk_note_share,
    c.account_risk_type,
    c.account_risk_level,
    c.is_test_account,
    c.is_internal_account,
    c.confirmed_cheat_flag,
    c.suspected_cheat_flag,
    c.category_missing_flag,
    c.baseline_fan_missing_flag,
    c.time_inconsistency_flag,
    CASE
        WHEN c.hard_invalid = 1 OR c.suspected_cheat_flag = 1 THEN 0 ELSE 1
    END AS is_valid,
    CASE
        WHEN c.hard_invalid = 1 OR c.suspected_cheat_flag = 1 THEN 0
        WHEN c.account_status IN ('封禁','注销') THEN 0
        ELSE 1
    END AS is_core_eligible,
    CASE
        WHEN c.creator_id IS NULL OR c.user_id IS NULL THEN 'S01_NULL_KEY'
        WHEN c.is_test_account = 1 THEN 'S02_TEST_ACCOUNT'
        WHEN c.is_internal_account = 1 THEN 'S03_INTERNAL_ACCOUNT'
        WHEN c.confirmed_cheat_flag = 1 OR c.suspected_cheat_flag = 1 THEN 'S04_CONFIRMED_OR_SUSPECTED_CHEAT'
        WHEN c.eligible_note_cnt = 0 OR c.first_valid_publish_at IS NULL THEN 'S11_NO_VALID_PUBLIC_NOTE'
        WHEN c.first_valid_publish_at > CAST('${hivevar:biz_date} 23:59:59' AS TIMESTAMP) THEN 'S17_FIRST_PUBLISH_AFTER_SNAPSHOT'
        WHEN c.account_status IN ('封禁','注销') THEN 'S12_STRUCTURAL_EXIT'
        WHEN c.account_created_at IS NULL OR c.creator_activated_at IS NULL THEN 'S13_INVALID_ACCOUNT_TIME'
        ELSE NULL
    END AS exclude_reason,
    CASE
        WHEN c.time_inconsistency_flag = 1 THEN 'SOURCE_LAST_BEFORE_FIRST'
        WHEN c.category_missing_flag = 1 THEN 'CATEGORY_MISSING'
        WHEN c.baseline_fan_missing_flag = 1 THEN 'BASELINE_FAN_MISSING'
        ELSE NULL
    END AS soft_anomaly_reason,
    CASE
        WHEN c.hard_invalid = 1 OR c.suspected_cheat_flag = 1 OR c.account_status IN ('封禁','注销') THEN '低'
        WHEN c.time_inconsistency_flag = 1 OR c.category_missing_flag = 1 OR c.baseline_fan_missing_flag = 1 THEN '中'
        ELSE '高'
    END AS quality_level,
    '${hivevar:metric_version}' AS metric_version
FROM creator_flags c;

-- ----------------------------------------------------------------------------
-- 分层：DWD
-- 业务口径：把笔记级硬过滤与创作者级硬过滤合并成最终可分析表
-- 统计窗口：2025-09-01~2026-03-31 笔记行为提取窗
-- 输出：DWD 笔记事实，DWS 只读取 is_core_eligible=1
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dwd_note_behavior_df (
    note_id                     STRING,
    creator_id                  STRING,
    publish_time                TIMESTAMP,
    content_type                STRING,
    content_category            STRING,
    topic_tag                   STRING,
    title_length                INT,
    body_length                 INT,
    image_cnt                   INT,
    content_quality_score       DECIMAL(8,4),
    has_product_link            INT,
    product_category            STRING,
    is_commercial_content       INT,
    distribution_pool           STRING,
    algorithm_version           STRING,
    platform_activity_id        STRING,
    note_status                 STRING,
    traffic_window_end_date     DATE,
    commerce_window_end_date    DATE,
    exposure_pv_7d              BIGINT,
    exposure_uv_7d              BIGINT,
    click_pv_7d                 BIGINT,
    click_uv_7d                 BIGINT,
    avg_read_seconds_7d         DECIMAL(12,4),
    completion_rate_7d          DECIMAL(12,8),
    like_cnt_7d                 BIGINT,
    comment_cnt_7d              BIGINT,
    favorite_cnt_7d             BIGINT,
    share_cnt_7d                BIGINT,
    interaction_cnt_7d          BIGINT,
    negative_feedback_cnt_7d    BIGINT,
    follow_cnt_7d               BIGINT,
    product_click_uv_30d        BIGINT,
    paid_order_cnt_30d          BIGINT,
    paid_buyer_uv_30d           BIGINT,
    gross_gmv_30d               DECIMAL(18,2),
    refund_gmv_30d              DECIMAL(18,2),
    net_gmv_30d                 DECIMAL(18,2),
    ad_revenue_30d              DECIMAL(18,2),
    commission_revenue_30d      DECIMAL(18,2),
    settlement_status           STRING,
    source_data_version         STRING,
    quality_level               STRING,
    is_valid                    INT,
    is_core_eligible            INT,
    exclude_reason              STRING,
    soft_anomaly_reason         STRING,
    metric_version              STRING
)
PARTITIONED BY (dt STRING)
STORED AS PARQUET;

INSERT OVERWRITE TABLE dwd_note_behavior_df PARTITION (dt='${hivevar:biz_date}')
SELECT
    n.note_id,
    n.creator_id,
    n.publish_time,
    n.content_type,
    n.content_category,
    n.topic_tag,
    n.title_length,
    n.body_length,
    n.image_cnt,
    n.content_quality_score,
    n.has_product_link,
    n.product_category,
    n.is_commercial_content,
    n.distribution_pool,
    n.algorithm_version,
    n.platform_activity_id,
    n.note_status,
    n.traffic_window_end_date,
    n.commerce_window_end_date,
    n.exposure_pv_7d,
    n.exposure_uv_7d,
    n.click_pv_7d,
    n.click_uv_7d,
    n.avg_read_seconds_7d,
    n.completion_rate_7d,
    n.like_cnt_7d,
    n.comment_cnt_7d,
    n.favorite_cnt_7d,
    n.share_cnt_7d,
    n.interaction_cnt_7d,
    n.negative_feedback_cnt_7d,
    n.follow_cnt_7d,
    n.product_click_uv_30d,
    n.paid_order_cnt_30d,
    n.paid_buyer_uv_30d,
    n.gross_gmv_30d,
    n.refund_gmv_30d,
    n.net_gmv_30d,
    n.ad_revenue_30d,
    n.commission_revenue_30d,
    n.settlement_status,
    n.data_version AS source_data_version,
    CASE
        WHEN n.is_hard_invalid = 1 OR c.is_core_eligible = 0 THEN '低'
        WHEN n.is_soft_anomaly = 1 THEN '中'
        ELSE n.quality_level
    END AS quality_level,
    CASE WHEN n.is_hard_invalid = 0 AND c.creator_id IS NOT NULL THEN 1 ELSE 0 END AS is_valid,
    CASE
        WHEN n.is_hard_invalid = 0
         AND n.is_base_eligible = 1
         AND c.is_core_eligible = 1 THEN 1
        ELSE 0
    END AS is_core_eligible,
    CASE
        WHEN n.hard_invalid_reason IS NOT NULL THEN n.hard_invalid_reason
        WHEN c.creator_id IS NULL THEN 'S14_ORPHAN_CREATOR'
        WHEN c.exclude_reason IS NOT NULL THEN c.exclude_reason
        ELSE NULL
    END AS exclude_reason,
    CASE
        WHEN n.soft_anomaly_reason IS NOT NULL AND c.soft_anomaly_reason IS NOT NULL
          THEN CONCAT(n.soft_anomaly_reason, ';', c.soft_anomaly_reason)
        ELSE COALESCE(n.soft_anomaly_reason, c.soft_anomaly_reason)
    END AS soft_anomaly_reason,
    '${hivevar:metric_version}' AS metric_version
FROM dwd_note_base_df n
LEFT JOIN dwd_creator_profile_df c
  ON n.creator_id = c.creator_id AND c.dt = '${hivevar:biz_date}'
WHERE n.dt = '${hivevar:biz_date}';
