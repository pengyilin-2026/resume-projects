#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
内容社区 APP 创作者成长与变现归因分析

运行方式（必须在项目根目录执行）：
    python code/creator_growth_attribution_analysis.py

输入：
    raw_data/creator_profile_20000.csv
    raw_data/note_behavior_100000.csv

输出：
    output/ 下的 CSV、PNG 和 analysis_summary.txt

依赖：
    pandas、matplotlib、seaborn
"""

from __future__ import annotations

import math
import os
import warnings
from pathlib import Path
from typing import Iterable

import pandas as pd
import matplotlib
from matplotlib import font_manager

# 必须在导入 pyplot 前设置 Agg，防止在无桌面环境或远程服务器上等待窗口。
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import seaborn as sns


# =============================================================================
# 0. 全局配置与通用工具
# =============================================================================

RAW_DIR = Path("raw_data")
OUTPUT_DIR = Path("output")
CREATOR_FILE = RAW_DIR / "creator_profile_20000.csv"
NOTE_FILE = RAW_DIR / "note_behavior_100000.csv"

SNAPSHOT_DATE = pd.Timestamp("2026-02-28")
FEATURE_START = pd.Timestamp("2025-09-01")
FEATURE_END = pd.Timestamp("2026-01-31 23:59:59")
LABEL_START = pd.Timestamp("2026-02-01")
LABEL_END = pd.Timestamp("2026-02-28 23:59:59")
DATA_EXTRACT_END = pd.Timestamp("2026-03-31 23:59:59")

METRIC_VERSION = "local_pandas_v1.0"

DATE_COLUMNS_CREATOR = [
    "account_created_at",
    "creator_activated_at",
    "first_publish_at",
    "last_publish_at",
    "snapshot_date",
    "feature_cutoff_date",
    "first_monetization_at",
    "churn_date",
]

DATE_COLUMNS_NOTE = [
    "publish_time",
    "traffic_window_end_date",
    "commerce_window_end_date",
]

NUMERIC_COLUMNS_CREATOR = [
    "creator_level",
    "baseline_fan_cnt",
    "first_7d_publish_cnt",
    "first_7d_exposure_uv",
    "first_7d_click_uv",
    "first_7d_interaction_cnt",
    "period_publish_cnt",
    "period_active_days",
    "period_exposure_uv",
    "period_click_uv",
    "period_interaction_cnt",
    "period_ad_revenue",
    "period_commission_revenue",
    "churn_label_eligible",
    "churn_28d",
]

NUMERIC_COLUMNS_NOTE = [
    "title_length",
    "body_length",
    "image_cnt",
    "content_quality_score",
    "has_product_link",
    "is_commercial_content",
    "exposure_pv_7d",
    "exposure_uv_7d",
    "click_pv_7d",
    "click_uv_7d",
    "avg_read_seconds_7d",
    "completion_rate_7d",
    "like_cnt_7d",
    "comment_cnt_7d",
    "favorite_cnt_7d",
    "share_cnt_7d",
    "interaction_cnt_7d",
    "negative_feedback_cnt_7d",
    "follow_cnt_7d",
    "product_click_uv_30d",
    "paid_order_cnt_30d",
    "paid_buyer_uv_30d",
    "gross_gmv_30d",
    "refund_gmv_30d",
    "net_gmv_30d",
    "ad_revenue_30d",
    "commission_revenue_30d",
]


def print_section(title: str) -> None:
    """统一打印模块标题，方便面试时按步骤讲解。"""
    print("\n" + "=" * 88)
    print(title)
    print("=" * 88)


def ensure_columns(
    data: pd.DataFrame,
    required_columns: Iterable[str],
    table_name: str,
) -> None:
    """检查关键字段是否存在；缺失字段补 NA 并告警，避免后续模块无提示崩掉。"""
    missing_columns = [col for col in required_columns if col not in data.columns]
    if missing_columns:
        warnings.warn(
            f"{table_name} 缺少关键字段：{missing_columns}。"
            "程序将继续运行，但对应指标会被标记为不可用。"
        )
        for column in missing_columns:
            data[column] = pd.NA


def safe_divide(numerator: pd.Series, denominator: pd.Series) -> pd.Series:
    """安全除法：分母为 0、空值或负数时返回 NaN，不用 0 冒充未知。"""
    denominator = pd.to_numeric(denominator, errors="coerce")
    numerator = pd.to_numeric(numerator, errors="coerce")
    result = numerator / denominator.where(denominator > 0)
    return result.replace([float("inf"), float("-inf")], pd.NA)


def combine_reasons(
    data: pd.DataFrame,
    conditions: list[tuple[str, pd.Series]],
) -> pd.Series:
    """把多个布尔条件合并成可追溯的原因字符串；同一记录可保留多个原因。"""
    reasons = pd.Series("", index=data.index, dtype="object")
    for reason, condition in conditions:
        condition = condition.fillna(False).astype(bool)
        has_reason = reasons.ne("")
        reasons = reasons.mask(condition & ~has_reason, reason)
        reasons = reasons.mask(condition & has_reason, reasons + ";" + reason)
    return reasons.replace("", pd.NA)


def quantile_bucket(series: pd.Series, q: int = 5) -> pd.Series:
    """
    稳定的分位分组函数。

    先 rank(method="first") 再 qcut，避免大量重复的 0 值导致 qcut 边界重复；
    小样本分组仍会按当前组内相对顺序给出尽可能均匀的组号。
    """
    result = pd.Series(pd.NA, index=series.index, dtype="Float64")
    valid = series.notna()
    if valid.sum() == 0:
        return result
    ranks = series.loc[valid].rank(method="first")
    if ranks.nunique() <= 1:
        result.loc[valid] = math.ceil(q / 2)
        return result
    try:
        bins = pd.qcut(ranks, q=q, labels=False, duplicates="drop") + 1
        result.loc[valid] = bins.astype(float)
    except ValueError:
        result.loc[valid] = ranks.rank(method="average", pct=False)
    return result


def save_csv(data: pd.DataFrame, filename: str, **kwargs) -> Path:
    """统一使用相对路径保存，禁止写死盘符。"""
    path = OUTPUT_DIR / filename
    data.to_csv(path, index=False, encoding="utf-8-sig", **kwargs)
    print(f"已保存：{path}，行数={len(data):,}")
    return path


def setup_plot_style() -> None:
    """配置中文字体、负号、分辨率和统一视觉风格。"""
    sns.set_theme(style="whitegrid", palette="Set2")

    preferred_fonts = [
        "Microsoft YaHei",
        "SimHei",
        "Noto Sans CJK SC",
        "Source Han Sans SC",
        "WenQuanYi Micro Hei",
        "PingFang SC",
        "Arial Unicode MS",
    ]

    # Windows 下 Matplotlib 有时不会自动扫描 TTC 字体，主动注册系统字体文件。
    windows_font_dir = Path(os.environ.get("WINDIR", "")) / "Fonts"
    for filename in ["msyh.ttc", "simhei.ttf", "msjh.ttc", "simsun.ttc"]:
        font_file = windows_font_dir / filename
        if font_file.exists():
            try:
                font_manager.fontManager.addfont(str(font_file))
            except Exception as exc:
                warnings.warn(f"注册中文字体失败：{font_file}，原因：{exc}")

    installed_font_names = {font.name for font in font_manager.fontManager.ttflist}
    selected_font = next(
        (name for name in preferred_fonts if name in installed_font_names),
        None,
    )
    if selected_font is None:
        warnings.warn(
            "未找到可用中文字体。请安装 Microsoft YaHei、SimHei 或 "
            "Noto Sans CJK SC，否则图片中的中文可能缺字。"
        )
        selected_font = "DejaVu Sans"

    plt.rcParams["font.family"] = "sans-serif"
    plt.rcParams["font.sans-serif"] = [selected_font, "DejaVu Sans"]
    plt.rcParams["axes.unicode_minus"] = False
    plt.rcParams["figure.dpi"] = 120
    plt.rcParams["savefig.dpi"] = 300
    plt.rcParams["axes.titlesize"] = 13
    plt.rcParams["axes.labelsize"] = 11
    plt.rcParams["xtick.labelsize"] = 9
    plt.rcParams["ytick.labelsize"] = 9
    plt.rcParams["legend.fontsize"] = 9


def add_figure_caption(fig: plt.Figure, text: str) -> None:
    """在图片底部写业务解读，避免图表离开文档后失去上下文。"""
    fig.text(
        0.01,
        0.01,
        text,
        ha="left",
        va="bottom",
        fontsize=9,
        color="#4B5563",
        wrap=True,
    )


# =============================================================================
# 1. 数据读取与合法性校验
# =============================================================================

print_section("1. 数据读取与合法性校验")

if not RAW_DIR.exists():
    raise FileNotFoundError(
        "未找到 raw_data 目录。请在项目根目录执行："
        "python code/creator_growth_attribution_analysis.py"
    )

if not CREATOR_FILE.exists() or not NOTE_FILE.exists():
    raise FileNotFoundError(
        f"缺少原始数据文件：{CREATOR_FILE} 或 {NOTE_FILE}"
    )


def load_raw_csv(
    path: Path,
    table_name: str,
    required_columns: list[str],
    date_columns: list[str],
    numeric_columns: list[str],
) -> pd.DataFrame:
    """
    读取原始 CSV，不覆盖源文件。

    这里只做类型转换和结构校验，不做任何物理删除；后续的硬/软异常都落在
    DWD 的标记列中，方便保留 ODS 到 DWD 的完整追溯链。
    """
    data = pd.read_csv(
        path,
        encoding="utf-8-sig",
        low_memory=False,
        dtype={
            "creator_id": "string",
            "user_id": "string",
            "note_id": "string",
            "platform_activity_id": "string",
            "data_version": "string",
        },
    )
    data["_source_row_id"] = range(1, len(data) + 1)

    ensure_columns(data, required_columns, table_name)

    for column in date_columns:
        original_non_null = data[column].notna().sum()
        data[column] = pd.to_datetime(data[column], errors="coerce")
        converted_non_null = data[column].notna().sum()
        if original_non_null != converted_non_null:
            warnings.warn(
                f"{table_name}.{column} 有 "
                f"{original_non_null - converted_non_null:,} 条无法转换为 datetime。"
            )

    for column in numeric_columns:
        if column in data.columns:
            data[column] = pd.to_numeric(data[column], errors="coerce")

    print(
        f"{table_name}: 行数={len(data):,}，列数={data.shape[1]:,}，"
        f"源文件={path.as_posix()}"
    )
    return data


creator_raw = load_raw_csv(
    CREATOR_FILE,
    "creator_profile",
    required_columns=[
        "creator_id",
        "user_id",
        "account_created_at",
        "creator_activated_at",
        "first_publish_at",
        "last_publish_at",
        "snapshot_date",
        "is_new_creator",
        "primary_category",
        "account_status",
        "churn_label_eligible",
        "churn_28d",
    ],
    date_columns=DATE_COLUMNS_CREATOR,
    numeric_columns=NUMERIC_COLUMNS_CREATOR,
)

note_raw = load_raw_csv(
    NOTE_FILE,
    "note_behavior",
    required_columns=[
        "note_id",
        "creator_id",
        "publish_time",
        "content_category",
        "note_status",
        "traffic_window_end_date",
        "commerce_window_end_date",
        "exposure_uv_7d",
        "click_uv_7d",
        "interaction_cnt_7d",
        "product_click_uv_30d",
        "paid_buyer_uv_30d",
        "gross_gmv_30d",
        "refund_gmv_30d",
        "ad_revenue_30d",
        "commission_revenue_30d",
        "settlement_status",
    ],
    date_columns=DATE_COLUMNS_NOTE,
    numeric_columns=NUMERIC_COLUMNS_NOTE,
)

creator_missing_id = creator_raw["creator_id"].isna().sum()
creator_missing_time = creator_raw["first_publish_at"].isna().sum()
note_missing_id = note_raw["note_id"].isna().sum() + note_raw["creator_id"].isna().sum()
note_missing_time = note_raw["publish_time"].isna().sum()

print(
    f"关键字段告警：创作者ID缺失={creator_missing_id:,}，"
    f"创作者首篇时间缺失={creator_missing_time:,}，"
    f"笔记关键ID缺失={note_missing_id:,}，笔记发布时间缺失={note_missing_time:,}"
)

creator_source_ids = set(creator_raw["creator_id"].dropna().astype(str))
note_creator_ids = set(note_raw["creator_id"].dropna().astype(str))
matched_creator_ids = creator_source_ids & note_creator_ids
print(
    "关联准备：笔记中可匹配创作者 "
    f"{len(matched_creator_ids):,}/{len(note_creator_ids):,}，"
    f"孤儿创作者ID={len(note_creator_ids - creator_source_ids):,}"
)


# =============================================================================
# 2. DWD 层：保留全部原始行，仅新增质量标记
# =============================================================================

print_section("2. DWD 层：清洗标记、硬异常与软异常")

OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

# -----------------------------------------------------------------------------
# 2.1 笔记 DWD
# -----------------------------------------------------------------------------

note_dwd = note_raw.copy()

# 缺失分类标签采用“未知类目”保留，不直接在 DWD 删除。
note_dwd["category_missing_flag"] = note_dwd["content_category"].isna().astype(int)
note_dwd["content_category"] = note_dwd["content_category"].fillna("未分类")

# 无商品链接时商品类目为空是预期缺失；挂链但类目为空才标记。
note_dwd["product_category_missing_flag"] = (
    (pd.to_numeric(note_dwd["has_product_link"], errors="coerce").fillna(0) == 1)
    & note_dwd["product_category"].isna()
).astype(int)
note_dwd.loc[
    (pd.to_numeric(note_dwd["has_product_link"], errors="coerce").fillna(0) == 1)
    & note_dwd["product_category"].isna(),
    "product_category",
] = "商品类目未知"

note_dwd["metric_window_complete"] = (
    note_dwd["traffic_window_end_date"].notna()
    & note_dwd["commerce_window_end_date"].notna()
    & (note_dwd["traffic_window_end_date"] <= DATA_EXTRACT_END)
    & (note_dwd["commerce_window_end_date"] <= DATA_EXTRACT_END)
    & note_dwd[
        [
            "exposure_uv_7d",
            "click_uv_7d",
            "interaction_cnt_7d",
            "product_click_uv_30d",
            "paid_buyer_uv_30d",
        ]
    ].notna().all(axis=1)
).astype(int)

# 重复上报不删除，只保留一条核心记录，其余打标记。优先已成熟窗口版本。
note_dwd["_metric_ready_for_dedup"] = note_dwd["metric_window_complete"]
duplicate_order = note_dwd.sort_values(
    [
        "_metric_ready_for_dedup",
        "data_version",
        "traffic_window_end_date",
        "commerce_window_end_date",
        "_source_row_id",
    ],
    ascending=[False, False, False, False, False],
    na_position="last",
)
note_dwd["_duplicate_rank"] = (
    duplicate_order.groupby("note_id", dropna=False).cumcount().add(1).sort_index()
)
note_dwd["duplicate_keep_flag"] = (note_dwd["_duplicate_rank"] == 1).astype(int)

note_dwd["interaction_sum_calc"] = (
    note_dwd[["like_cnt_7d", "comment_cnt_7d", "favorite_cnt_7d", "share_cnt_7d"]]
    .fillna(0)
    .sum(axis=1)
)

interaction_base = note_dwd["interaction_cnt_7d"].fillna(0)
follow_base = note_dwd["follow_cnt_7d"].fillna(0)
click_uv_safe = note_dwd["click_uv_7d"].fillna(0).clip(lower=1)
exposure_pv_safe = note_dwd["exposure_pv_7d"].fillna(0).clip(lower=1)

note_hard_conditions = [
    (
        "S01_NULL_KEY",
        note_dwd["note_id"].isna() | note_dwd["creator_id"].isna(),
    ),
    (
        "S02_DUPLICATE_REPORT",
        note_dwd["duplicate_keep_flag"].eq(0),
    ),
    (
        "S03_NOTE_NOT_PUBLIC",
        note_dwd["note_status"].fillna("").ne("公开"),
    ),
    (
        "S04_INVALID_PUBLISH_TIME",
        note_dwd["publish_time"].isna()
        | (note_dwd["publish_time"] > DATA_EXTRACT_END),
    ),
    (
        "S05_FUNNEL_LOGIC_ERROR",
        (note_dwd["click_uv_7d"] > note_dwd["exposure_uv_7d"])
        | (note_dwd["click_pv_7d"] > note_dwd["exposure_pv_7d"])
        | (note_dwd["click_pv_7d"] < note_dwd["click_uv_7d"])
        | (note_dwd["exposure_pv_7d"] < note_dwd["exposure_uv_7d"]),
    ),
    (
        "S06_ZERO_EXPOSURE_REVENUE",
        note_dwd["exposure_uv_7d"].eq(0)
        & (
            (note_dwd["ad_revenue_30d"].fillna(0) > 10)
            | (note_dwd["commission_revenue_30d"].fillna(0) > 50)
        ),
    ),
    (
        "S07_COMMERCE_LOGIC_ERROR",
        (note_dwd["paid_buyer_uv_30d"] > note_dwd["product_click_uv_30d"])
        | (
            note_dwd["product_click_uv_30d"].fillna(0).gt(0)
            & note_dwd["has_product_link"].fillna(0).eq(0)
        )
        | (
            note_dwd["gross_gmv_30d"].fillna(0).gt(0)
            & note_dwd["has_product_link"].fillna(0).eq(0)
        )
        | (note_dwd["refund_gmv_30d"].fillna(0) > note_dwd["gross_gmv_30d"].fillna(0)),
    ),
    (
        "S08_INTERACTION_RECON_ERROR",
        note_dwd["interaction_cnt_7d"].fillna(0) != note_dwd["interaction_sum_calc"],
    ),
    (
        "S09_INVALID_RATE_RANGE",
        note_dwd["completion_rate_7d"].lt(0)
        | note_dwd["completion_rate_7d"].gt(1),
    ),
    (
        "S10_NEGATIVE_METRIC",
        note_dwd[
            [
                "exposure_uv_7d",
                "click_uv_7d",
                "interaction_cnt_7d",
                "paid_order_cnt_30d",
                "gross_gmv_30d",
                "refund_gmv_30d",
                "ad_revenue_30d",
                "commission_revenue_30d",
            ]
        ]
        .lt(0)
        .any(axis=1),
    ),
]

note_dwd["exclude_reason"] = combine_reasons(note_dwd, note_hard_conditions)
note_dwd["is_hard_invalid"] = note_dwd["exclude_reason"].notna().astype(int)

# 观察窗未成熟或核心数值缺失不是“脏数据”，但同样不进入核心指标。
note_window_reason = pd.Series(
    pd.NA,
    index=note_dwd.index,
    dtype="object",
)
note_window_reason.loc[
    note_dwd["exclude_reason"].isna()
    & note_dwd["metric_window_complete"].eq(0)
] = "S11_METRIC_WINDOW_INCOMPLETE"
note_dwd["exclude_reason"] = note_dwd["exclude_reason"].fillna(note_window_reason)

interaction_anomaly = (
    interaction_base > 12 * click_uv_safe
) & (interaction_base >= 1000)
follow_anomaly = (
    follow_base > 0.2 * click_uv_safe
) & (follow_base >= 500)
negative_feedback_anomaly = (
    note_dwd["negative_feedback_cnt_7d"].fillna(0) > 0.05 * exposure_pv_safe
)
read_time_anomaly = note_dwd["avg_read_seconds_7d"].fillna(0) > 3600
small_zero_exposure_revenue = (
    note_dwd["exposure_uv_7d"].eq(0)
    & (
        note_dwd["ad_revenue_30d"].fillna(0).gt(0)
        | note_dwd["commission_revenue_30d"].fillna(0).gt(0)
    )
    & note_dwd["exclude_reason"].isna()
)

note_soft_conditions = [
    ("SOFT_INTERACTION_ABOVE_12X_AND_1000", interaction_anomaly),
    ("SOFT_FOLLOW_RATE_ABOVE_20PCT", follow_anomaly),
    ("SOFT_NEGATIVE_FEEDBACK_ABOVE_5PCT", negative_feedback_anomaly),
    ("SOFT_READ_TIME_ABOVE_1H", read_time_anomaly),
    ("SOFT_ZERO_EXPOSURE_SMALL_REVENUE", small_zero_exposure_revenue),
]

note_dwd["soft_anomaly_reason"] = combine_reasons(note_dwd, note_soft_conditions)
note_dwd["is_soft_anomaly"] = note_dwd["soft_anomaly_reason"].notna().astype(int)
note_dwd["is_behavior_risk_note"] = (
    interaction_anomaly | follow_anomaly
).astype(int)
note_dwd["note_level_core_eligible"] = note_dwd["exclude_reason"].isna().astype(int)
note_dwd["quality_level"] = "高"
note_dwd.loc[note_dwd["is_soft_anomaly"].eq(1), "quality_level"] = "中"
note_dwd.loc[note_dwd["note_level_core_eligible"].eq(0), "quality_level"] = "低"

# -----------------------------------------------------------------------------
# 2.2 创作者 DWD
# -----------------------------------------------------------------------------

creator_dwd = creator_raw.copy()
creator_dwd["primary_category_missing_flag"] = creator_dwd["primary_category"].isna().astype(int)
creator_dwd["primary_category"] = creator_dwd["primary_category"].fillna("未分类")
creator_dwd["baseline_fan_missing_flag"] = creator_dwd["baseline_fan_cnt"].isna().astype(int)

creator_dwd["support_group"] = creator_dwd["support_group"].fillna("未知扶持")
creator_dwd.loc[
    creator_dwd["is_new_creator"].fillna(0).eq(0)
    & creator_dwd["support_group"].eq("未知扶持"),
    "support_group",
] = "无扶持"

creator_dwd["creator_level"] = creator_dwd["creator_level"].fillna(-1).astype(int)
creator_dwd["creator_level_label"] = creator_dwd["creator_level"].map(
    lambda value: "未分层" if value == -1 else str(value)
)

# 创作者重复上报同样保留全部行，只标记一条核心记录。
creator_duplicate_order = creator_dwd.sort_values(
    ["data_version", "snapshot_date", "_source_row_id"],
    ascending=[False, False, False],
    na_position="last",
)
creator_dwd["_duplicate_rank"] = (
    creator_duplicate_order.groupby("creator_id", dropna=False)
    .cumcount()
    .add(1)
    .sort_index()
)
creator_dwd["duplicate_keep_flag"] = (creator_dwd["_duplicate_rank"] == 1).astype(int)

# 账号状态只使用现有两张基础表可获得的字段；真实生产可替换为治理维表 risk_type。
account_status_normalized = creator_dwd["account_status"].fillna("未知")
is_test_account = account_status_normalized.isin(["测试"])
is_internal_account = account_status_normalized.isin(["内部", "内部运营"])
is_confirmed_cheat = account_status_normalized.isin(["作弊", "风控确认"])
is_structural_exit = account_status_normalized.isin(["封禁", "注销"])

valid_note_for_creator = note_dwd[note_dwd["note_level_core_eligible"].eq(1)].copy()
creator_note_dates = (
    valid_note_for_creator.groupby("creator_id", as_index=False)
    .agg(
        first_valid_publish_at=("publish_time", "min"),
        last_valid_publish_at=("publish_time", "max"),
        eligible_note_cnt=("note_id", "count"),
    )
)

creator_behavior_risk = (
    note_dwd.groupby("creator_id", as_index=False)
    .agg(
        behavior_risk_note_cnt=("is_behavior_risk_note", "sum"),
        public_note_cnt=("note_level_core_eligible", "sum"),
    )
)
creator_behavior_risk["behavior_risk_note_share"] = safe_divide(
    creator_behavior_risk["behavior_risk_note_cnt"],
    creator_behavior_risk["public_note_cnt"],
).fillna(0)

creator_dwd = creator_dwd.merge(
    creator_note_dates,
    on="creator_id",
    how="left",
    validate="many_to_one",
)
creator_dwd = creator_dwd.merge(
    creator_behavior_risk,
    on="creator_id",
    how="left",
    validate="many_to_one",
)

creator_dwd["behavior_risk_note_cnt"] = creator_dwd["behavior_risk_note_cnt"].fillna(0)
creator_dwd["public_note_cnt"] = creator_dwd["public_note_cnt"].fillna(0)
creator_dwd["behavior_risk_note_share"] = creator_dwd["behavior_risk_note_share"].fillna(0)

# 单篇异常不直接判作弊；账号级重复异常才升级为可疑账号。
suspected_cheat = (
    (
        creator_dwd["behavior_risk_note_cnt"].ge(2)
        & creator_dwd["behavior_risk_note_share"].ge(0.2)
    )
    | creator_dwd["behavior_risk_note_cnt"].ge(5)
)

creator_dwd["time_inconsistency_flag"] = (
    creator_dwd["first_publish_at"].notna()
    & creator_dwd["last_publish_at"].notna()
    & (creator_dwd["first_publish_at"] > creator_dwd["last_publish_at"])
).astype(int)

creator_hard_conditions = [
    (
        "S01_NULL_KEY",
        creator_dwd["creator_id"].isna() | creator_dwd["user_id"].isna(),
    ),
    (
        "S02_DUPLICATE_REPORT",
        creator_dwd["duplicate_keep_flag"].eq(0),
    ),
    ("S03_TEST_ACCOUNT", is_test_account),
    ("S04_INTERNAL_ACCOUNT", is_internal_account),
    ("S05_CONFIRMED_CHEAT", is_confirmed_cheat),
    ("S06_SUSPECTED_CHEAT", suspected_cheat),
    (
        "S07_NO_VALID_PUBLIC_NOTE",
        creator_dwd["first_valid_publish_at"].isna(),
    ),
    (
        "S08_INVALID_ACCOUNT_TIME",
        creator_dwd["account_created_at"].isna()
        | creator_dwd["creator_activated_at"].isna(),
    ),
    (
        "S09_FIRST_PUBLISH_AFTER_SNAPSHOT",
        creator_dwd["first_valid_publish_at"] > SNAPSHOT_DATE,
    ),
    ("S10_STRUCTURAL_EXIT", is_structural_exit),
]

creator_dwd["exclude_reason"] = combine_reasons(creator_dwd, creator_hard_conditions)
creator_dwd["is_valid"] = creator_dwd["exclude_reason"].isna().astype(int)
creator_dwd["is_core_eligible"] = creator_dwd["exclude_reason"].isna().astype(int)

creator_soft_conditions = [
    (
        "SOFT_CATEGORY_MISSING",
        creator_dwd["primary_category_missing_flag"].eq(1),
    ),
    (
        "SOFT_BASELINE_FAN_MISSING",
        creator_dwd["baseline_fan_missing_flag"].eq(1),
    ),
    (
        "SOFT_SOURCE_LAST_BEFORE_FIRST",
        creator_dwd["time_inconsistency_flag"].eq(1),
    ),
]
creator_dwd["soft_anomaly_reason"] = combine_reasons(
    creator_dwd,
    creator_soft_conditions,
)
creator_dwd["quality_level"] = "高"
creator_dwd.loc[
    creator_dwd["soft_anomaly_reason"].notna(),
    "quality_level",
] = "中"
creator_dwd.loc[
    creator_dwd["is_core_eligible"].eq(0),
    "quality_level",
] = "低"

# -----------------------------------------------------------------------------
# 2.3 笔记 DWD 最终合并创作者过滤结果
# -----------------------------------------------------------------------------

creator_flags_for_note = creator_dwd[
    [
        "creator_id",
        "is_core_eligible",
        "exclude_reason",
        "soft_anomaly_reason",
        "quality_level",
        "is_new_creator",
        "account_status",
    ]
].rename(
    columns={
        "is_core_eligible": "creator_core_eligible",
        "exclude_reason": "creator_exclude_reason",
        "soft_anomaly_reason": "creator_soft_anomaly_reason",
        "quality_level": "creator_quality_level",
        "is_new_creator": "creator_is_new",
        "account_status": "creator_account_status",
    }
)

notes_before_creator_merge = len(note_dwd)
note_dwd = note_dwd.merge(
    creator_flags_for_note,
    on="creator_id",
    how="left",
    validate="many_to_one",
)
assert len(note_dwd) == notes_before_creator_merge, "合并创作者标记时发生了行数变化"

note_dwd["is_core_eligible"] = (
    note_dwd["note_level_core_eligible"].eq(1)
    & note_dwd["creator_core_eligible"].fillna(0).eq(1)
).astype(int)

note_final_reasons = []
for row in note_dwd[
    ["exclude_reason", "creator_exclude_reason"]
].itertuples(index=False, name=None):
    parts = []
    for value in row:
        if pd.notna(value) and str(value).strip():
            parts.extend(str(value).split(";"))
    note_final_reasons.append(";".join(dict.fromkeys(parts)) if parts else pd.NA)
note_dwd["exclude_reason"] = note_final_reasons

note_soft_reasons = []
for row in note_dwd[
    ["soft_anomaly_reason", "creator_soft_anomaly_reason"]
].itertuples(index=False, name=None):
    parts = []
    for value in row:
        if pd.notna(value) and str(value).strip():
            parts.extend(str(value).split(";"))
    note_soft_reasons.append(";".join(dict.fromkeys(parts)) if parts else pd.NA)
note_dwd["soft_anomaly_reason"] = note_soft_reasons

note_dwd["quality_level"] = "高"
note_dwd.loc[note_dwd["soft_anomaly_reason"].notna(), "quality_level"] = "中"
note_dwd.loc[note_dwd["is_core_eligible"].eq(0), "quality_level"] = "低"
note_dwd["metric_version"] = METRIC_VERSION
creator_dwd["metric_version"] = METRIC_VERSION

# DWD 质量结果
note_quality_report = pd.DataFrame(
    {
        "指标": [
            "ODS笔记行数",
            "DWD笔记行数",
            "DWD核心可用笔记",
            "硬异常标记行数",
            "软异常标记行数",
            "重复上报标记行数",
            "测试账号创作者数",
            "结构性退出创作者数",
            "疑似作弊创作者数",
        ],
        "数值": [
            len(note_raw),
            len(note_dwd),
            int(note_dwd["is_core_eligible"].sum()),
            int(note_dwd["is_hard_invalid"].sum()),
            int(note_dwd["is_soft_anomaly"].sum()),
            int(note_dwd["duplicate_keep_flag"].eq(0).sum()),
            int(is_test_account.sum()),
            int(is_structural_exit.sum()),
            int(suspected_cheat.sum()),
        ],
    }
)

print(note_quality_report.to_string(index=False))
print(
    f"DWD行数校验：原始笔记={len(note_raw):,}，清洗标记后={len(note_dwd):,}；"
    "未删除任何 ODS 行。"
)

# 导出 DWD 供人工核对：包含原始字段和新增质量标记，不修改 raw_data。
save_csv(note_dwd, "dwd_note_mid.csv")
save_csv(creator_dwd, "dwd_creator_mid.csv")
save_csv(note_quality_report, "data_quality_report.csv")


# =============================================================================
# 3. DWS 层：生命周期、7/14 天留存
# =============================================================================

print_section("3. DWS 层：创作者生命周期与 7/14 天留存")

note_core = note_dwd[note_dwd["is_core_eligible"].eq(1)].copy()
creator_core = creator_dwd[creator_dwd["is_core_eligible"].eq(1)].copy()

if note_core.empty or creator_core.empty:
    raise RuntimeError("DWD 中没有合格创作者或笔记，请先检查质量标记。")

# 计算每篇笔记相对首篇的天数，所有留存均以“首篇有效公开笔记”为起点。
first_note = (
    note_core.sort_values(["creator_id", "publish_time", "note_id"])
    .drop_duplicates("creator_id", keep="first")[
        ["creator_id", "note_id", "publish_time", "content_category"]
    ]
    .rename(
        columns={
            "note_id": "first_note_id",
            "publish_time": "first_note_at",
            "content_category": "first_note_category",
        }
    )
)

note_with_first = note_core.merge(
    first_note[["creator_id", "first_note_at"]],
    on="creator_id",
    how="left",
    validate="many_to_one",
)
note_with_first["days_since_first"] = (
    note_with_first["publish_time"].dt.normalize()
    - note_with_first["first_note_at"].dt.normalize()
).dt.days

creator_note_stats = (
    note_core.groupby("creator_id", as_index=False)
    .agg(
        first_valid_publish_at=("publish_time", "min"),
        last_valid_publish_at=("publish_time", "max"),
        valid_note_cnt=("note_id", "count"),
        active_day_cnt=("publish_time", lambda s: s.dt.normalize().nunique()),
    )
)

feature_note = note_core[
    note_core["publish_time"].between(FEATURE_START, FEATURE_END, inclusive="both")
].copy()
feature_note["settled_revenue"] = feature_note.apply(
    lambda row: (
        float(row.get("ad_revenue_30d") or 0)
        + float(row.get("commission_revenue_30d") or 0)
        if row.get("settlement_status") == "已结算"
        else 0.0
    ),
    axis=1,
)

creator_feature_stats = (
    feature_note.groupby("creator_id", as_index=False)
    .agg(
        feature_note_cnt=("note_id", "count"),
        feature_exposure_uv=("exposure_uv_7d", "sum"),
        feature_click_uv=("click_uv_7d", "sum"),
        feature_interaction_cnt=("interaction_cnt_7d", "sum"),
        settled_revenue_feature=("settled_revenue", "sum"),
    )
)

recent_note = note_core[
    note_core["publish_time"].between(
        SNAPSHOT_DATE - pd.Timedelta(days=27),
        SNAPSHOT_DATE,
        inclusive="both",
    )
]
creator_recent_stats = (
    recent_note.groupby("creator_id", as_index=False)
    .agg(valid_note_cnt_28d=("note_id", "count"))
)

retention_stats = (
    note_with_first.assign(
        in_first_7=note_with_first["days_since_first"].between(1, 7),
        in_first_14=note_with_first["days_since_first"].between(1, 14),
    )
    .groupby("creator_id", as_index=False)
    .agg(
        retained_7d_flag=("in_first_7", "max"),
        retained_14d_flag=("in_first_14", "max"),
    )
)

# 连续创作：相邻活跃日间隔 <= 7 天视为一段连续的创作期。
active_dates = note_core[["creator_id", "publish_time"]].copy()
active_dates["active_date"] = active_dates["publish_time"].dt.normalize()
active_dates = active_dates[["creator_id", "active_date"]].drop_duplicates()
active_dates = active_dates.sort_values(["creator_id", "active_date"])
active_dates["prev_active_date"] = active_dates.groupby("creator_id")["active_date"].shift(1)
active_dates["new_run"] = (
    active_dates["prev_active_date"].isna()
    | (
        active_dates["active_date"] - active_dates["prev_active_date"]
    ).dt.days.gt(7)
).astype(int)
active_dates["run_id"] = active_dates.groupby("creator_id")["new_run"].cumsum()
continuous_stats = (
    active_dates.groupby(["creator_id", "run_id"], as_index=False)
    .agg(run_start=("active_date", "min"), run_end=("active_date", "max"))
)
continuous_stats["run_span_days"] = (
    continuous_stats["run_end"] - continuous_stats["run_start"]
).dt.days + 1
continuous_stats = (
    continuous_stats.groupby("creator_id", as_index=False)
    .agg(continuous_creation_days=("run_span_days", "max"))
)

creator_core_for_lifecycle = creator_core.drop(
    columns=["first_valid_publish_at", "last_valid_publish_at"],
    errors="ignore",
)

dws_creator_lifecycle = creator_core_for_lifecycle.merge(
    creator_note_stats,
    on="creator_id",
    how="left",
    validate="one_to_one",
)
dws_creator_lifecycle = dws_creator_lifecycle.merge(
    creator_feature_stats,
    on="creator_id",
    how="left",
    validate="one_to_one",
)
dws_creator_lifecycle = dws_creator_lifecycle.merge(
    creator_recent_stats,
    on="creator_id",
    how="left",
    validate="one_to_one",
)
dws_creator_lifecycle = dws_creator_lifecycle.merge(
    retention_stats,
    on="creator_id",
    how="left",
    validate="one_to_one",
)
dws_creator_lifecycle = dws_creator_lifecycle.merge(
    continuous_stats,
    on="creator_id",
    how="left",
    validate="one_to_one",
)

dws_creator_lifecycle["creator_tenure_days"] = (
    SNAPSHOT_DATE.normalize()
    - dws_creator_lifecycle["first_valid_publish_at"].dt.normalize()
).dt.days + 1

dws_creator_lifecycle["create_span_days"] = (
    dws_creator_lifecycle["last_valid_publish_at"].dt.normalize()
    - dws_creator_lifecycle["first_valid_publish_at"].dt.normalize()
).dt.days + 1

dws_creator_lifecycle["silent_days"] = (
    SNAPSHOT_DATE.normalize()
    - dws_creator_lifecycle["last_valid_publish_at"].dt.normalize()
).dt.days.clip(lower=0)

dws_creator_lifecycle["creator_tenure_days"] = (
    dws_creator_lifecycle["creator_tenure_days"].clip(lower=0)
)

dws_creator_lifecycle["retained_7d_eligible"] = (
    dws_creator_lifecycle["is_new_creator"].fillna(0).eq(1)
    & (
        dws_creator_lifecycle["first_valid_publish_at"]
        + pd.Timedelta(days=7)
        <= DATA_EXTRACT_END
    )
)

dws_creator_lifecycle["retained_14d_eligible"] = (
    dws_creator_lifecycle["is_new_creator"].fillna(0).eq(1)
    & (
        dws_creator_lifecycle["first_valid_publish_at"]
        + pd.Timedelta(days=14)
        <= DATA_EXTRACT_END
    )
)

dws_creator_lifecycle["retained_7d"] = pd.Series(
    pd.NA,
    index=dws_creator_lifecycle.index,
    dtype="Float64",
)
dws_creator_lifecycle.loc[
    dws_creator_lifecycle["retained_7d_eligible"],
    "retained_7d",
] = (
    dws_creator_lifecycle.loc[
        dws_creator_lifecycle["retained_7d_eligible"],
        "retained_7d_flag",
    ]
    .astype(float)
)

dws_creator_lifecycle["retained_14d"] = pd.Series(
    pd.NA,
    index=dws_creator_lifecycle.index,
    dtype="Float64",
)
dws_creator_lifecycle.loc[
    dws_creator_lifecycle["retained_14d_eligible"],
    "retained_14d",
] = (
    dws_creator_lifecycle.loc[
        dws_creator_lifecycle["retained_14d_eligible"],
        "retained_14d_flag",
    ]
    .astype(float)
)

for column in [
    "feature_note_cnt",
    "feature_exposure_uv",
    "feature_click_uv",
    "feature_interaction_cnt",
    "settled_revenue_feature",
    "valid_note_cnt_28d",
]:
    dws_creator_lifecycle[column] = dws_creator_lifecycle[column].fillna(0)

dws_creator_lifecycle["monetizing_flag"] = (
    dws_creator_lifecycle["settled_revenue_feature"] > 0
).astype(int)

new_creator_lifecycle = dws_creator_lifecycle[
    dws_creator_lifecycle["is_new_creator"].fillna(0).eq(1)
].copy()

d7_eligible = new_creator_lifecycle[new_creator_lifecycle["retained_7d_eligible"]]
d14_eligible = new_creator_lifecycle[new_creator_lifecycle["retained_14d_eligible"]]
d7_rate = d7_eligible["retained_7d"].mean() if len(d7_eligible) else float("nan")
d14_rate = d14_eligible["retained_14d"].mean() if len(d14_eligible) else float("nan")

print(
    f"新人样本={len(new_creator_lifecycle):,}；"
    f"D7可评估={len(d7_eligible):,}，D7留存率={d7_rate:.2%}；"
    f"D14可评估={len(d14_eligible):,}，D14留存率={d14_rate:.2%}。"
)

# 导出生命周期 DWS
lifecycle_columns = [
    "creator_id",
    "user_id",
    "is_new_creator",
    "primary_category",
    "cohort_month",
    "support_group",
    "first_valid_publish_at",
    "last_valid_publish_at",
    "creator_tenure_days",
    "create_span_days",
    "continuous_creation_days",
    "silent_days",
    "valid_note_cnt_28d",
    "feature_note_cnt",
    "feature_exposure_uv",
    "feature_click_uv",
    "feature_interaction_cnt",
    "settled_revenue_feature",
    "monetizing_flag",
    "retained_7d",
    "retained_7d_eligible",
    "retained_14d",
    "retained_14d_eligible",
    "churn_label_eligible",
    "churn_28d",
    "quality_level",
]
save_csv(
    dws_creator_lifecycle[lifecycle_columns],
    "dws_creator_lifecycle.csv",
)


# =============================================================================
# 4. 定制创作者三维分层模型
# =============================================================================

print_section("4. 创作者三维分层：活跃度 × 流量效率 × 变现价值")

creator_dimension = dws_creator_lifecycle.copy()
creator_dimension["traffic_efficiency"] = safe_divide(
    creator_dimension["feature_click_uv"],
    creator_dimension["feature_exposure_uv"],
).fillna(0)

# 三个维度分别取当前合格创作者的分位数，不硬编码固定业务数字。
activity_p40 = creator_dimension["valid_note_cnt_28d"].quantile(0.40)
activity_p50 = creator_dimension["valid_note_cnt_28d"].quantile(0.50)
activity_p80 = creator_dimension["valid_note_cnt_28d"].quantile(0.80)

traffic_p40 = creator_dimension["traffic_efficiency"].quantile(0.40)
traffic_p50 = creator_dimension["traffic_efficiency"].quantile(0.50)
traffic_p80 = creator_dimension["traffic_efficiency"].quantile(0.80)

revenue_p40 = creator_dimension["settled_revenue_feature"].quantile(0.40)
revenue_p80 = creator_dimension["settled_revenue_feature"].quantile(0.80)

creator_dimension["activity_percentile"] = (
    creator_dimension["valid_note_cnt_28d"].rank(pct=True, method="average") * 100
)
creator_dimension["traffic_percentile"] = (
    creator_dimension["traffic_efficiency"].rank(pct=True, method="average") * 100
)
creator_dimension["revenue_percentile"] = creator_dimension[
    "settled_revenue_feature"
].rank(pct=True, method="average") * 100

active_recent = creator_dimension["valid_note_cnt_28d"] > 0
high_activity = creator_dimension["activity_percentile"] >= 50
high_traffic = creator_dimension["traffic_percentile"] >= 50
top_revenue = creator_dimension["revenue_percentile"] >= 80

segment_labels = pd.Series(
    "低价值流失群体",
    index=creator_dimension.index,
    dtype="object",
)

# 分层顺序体现运营识别优先级：
# 1）潜力新人优先识别，避免被成熟创作者的绝对收益掩盖；
# 2）头部高收益按当前变现分位；
# 3）其余近 28 日活跃且活跃/流量至少一项位于中位以上者为腰部稳定；
# 4）其余为低价值流失群体。
potential_newcomer = (
    creator_dimension["is_new_creator"].fillna(0).eq(1)
    & active_recent
    & high_activity
    & high_traffic
)
head_high_revenue = top_revenue & active_recent
stable_middle = (
    active_recent
    & (
        (creator_dimension["activity_percentile"] >= 40)
        | (creator_dimension["traffic_percentile"] >= 40)
    )
)

segment_labels.loc[stable_middle] = "腰部稳定"
segment_labels.loc[head_high_revenue] = "头部高收益"
segment_labels.loc[potential_newcomer] = "潜力新人"

creator_dimension["creator_segment_3d"] = segment_labels

segment_thresholds = pd.DataFrame(
    [
        {
            "维度": "创作活跃度",
            "指标": "快照前28日有效公开笔记数",
            "P40": activity_p40,
            "P50": activity_p50,
            "P80": activity_p80,
            "业务解释": (
                "P40用于区分低频创作，P50用于识别中位以上持续输出，"
                "P80代表近期高频创作。阈值由本次合格样本计算。"
            ),
        },
        {
            "维度": "内容流量效率",
            "指标": "特征窗点击UV/曝光UV",
            "P40": traffic_p40,
            "P50": traffic_p50,
            "P80": traffic_p80,
            "业务解释": (
                "用点击UV/曝光UV衡量内容被看见后的点击效率，"
                "避免粉丝量较大的创作者天然进入头部。"
            ),
        },
        {
            "维度": "变现价值",
            "指标": "特征窗已结算广告分成+佣金",
            "P40": revenue_p40,
            "P50": float("nan"),
            "P80": revenue_p80,
            "业务解释": (
                "P80识别平台已验证的高收益创作者；"
                "P40用于识别低变现贡献，不用GMV代替创作者收益。"
            ),
        },
    ]
)

segment_rule_text = pd.DataFrame(
    [
        {
            "群体": "潜力新人",
            "规则": (
                "新人 & 近28日有发布 & 活跃度分位>=P50 "
                "& 流量效率分位>=P50"
            ),
            "业务解释": "近期持续创作且首轮流量效率优于同批中位数的新人。",
        },
        {
            "群体": "头部高收益",
            "规则": "变现价值分位>=P80 & 近28日有发布",
            "业务解释": "平台已验证变现能力且仍保持近期发布的核心供给。",
        },
        {
            "群体": "腰部稳定",
            "规则": (
                "近28日有发布 & (活跃度>=P40 或 流量效率>=P40)，"
                "且未命中潜力新人/头部"
            ),
            "业务解释": "仍在持续供给、但未进入最高变现分位的稳定创作者。",
        },
        {
            "群体": "低价值流失群体",
            "规则": (
                "未命中以上群体；通常为近28日无发布，"
                "或活跃、流量、收益均处于较低分位"
            ),
            "业务解释": "当前内容贡献和变现贡献较弱，需要进一步诊断停更与内容适配。",
        },
    ]
)

print(
    "三维阈值："
    f"活跃度P40={activity_p40:.2f}篇，P80={activity_p80:.2f}篇；"
    f"流量效率P40={traffic_p40:.4%}，P80={traffic_p80:.4%}；"
    f"变现价值P40=￥{revenue_p40:,.2f}，P80=￥{revenue_p80:,.2f}。"
)
print(creator_dimension["creator_segment_3d"].value_counts().to_string())
print("分层说明：")
print(segment_rule_text.to_string(index=False))

save_csv(segment_thresholds, "creator_segment_thresholds.csv")
save_csv(segment_rule_text, "creator_segment_rule_text.csv")
save_csv(
    creator_dimension[
        [
            "creator_id",
            "is_new_creator",
            "primary_category",
            "valid_note_cnt_28d",
            "traffic_efficiency",
            "settled_revenue_feature",
            "activity_percentile",
            "traffic_percentile",
            "revenue_percentile",
            "creator_segment_3d",
        ]
    ],
    "creator_three_dim_segments.csv",
)


# =============================================================================
# 5. 新人首篇表现分群与 7/14 天留存
# =============================================================================

print_section("5. 新人首篇表现分群与留存")

new_creator = creator_dimension[
    creator_dimension["is_new_creator"].fillna(0).eq(1)
].copy()
new_creator = new_creator.rename(
    columns={"first_7d_publish_cnt": "source_first_7d_publish_cnt"}
)

first_note_detail = first_note.merge(
    note_core[
        [
            "note_id",
            "exposure_uv_7d",
            "click_uv_7d",
            "interaction_cnt_7d",
            "product_click_uv_30d",
            "paid_buyer_uv_30d",
        ]
    ],
    left_on="first_note_id",
    right_on="note_id",
    how="left",
)

first_note_detail["first_note_ctr"] = safe_divide(
    first_note_detail["click_uv_7d"],
    first_note_detail["exposure_uv_7d"],
).fillna(0)
first_note_detail["first_note_interaction_rate"] = safe_divide(
    first_note_detail["interaction_cnt_7d"],
    first_note_detail["click_uv_7d"],
).fillna(0)
first_note_detail["first_note_product_click_rate"] = safe_divide(
    first_note_detail["product_click_uv_30d"],
    first_note_detail["click_uv_7d"],
).fillna(0)

first_week_stats = (
    note_with_first[
        note_with_first["days_since_first"].between(0, 7)
    ]
    .groupby("creator_id", as_index=False)
    .agg(first_7d_publish_cnt=("note_id", "count"))
)

new_creator_detail = new_creator.merge(
    first_note_detail[
        [
            "creator_id",
            "first_note_at",
            "first_note_category",
            "exposure_uv_7d",
            "click_uv_7d",
            "interaction_cnt_7d",
            "first_note_ctr",
            "first_note_interaction_rate",
            "first_note_product_click_rate",
            "paid_buyer_uv_30d",
        ]
    ].rename(
        columns={
            "exposure_uv_7d": "first_note_exposure_uv",
            "click_uv_7d": "first_note_click_uv",
            "interaction_cnt_7d": "first_note_interaction_cnt",
            "paid_buyer_uv_30d": "first_note_paid_buyer_uv",
        }
    ),
    on="creator_id",
    how="left",
    validate="one_to_one",
)
new_creator_detail = new_creator_detail.merge(
    first_week_stats,
    on="creator_id",
    how="left",
    validate="one_to_one",
)
new_creator_detail["first_7d_publish_cnt"] = new_creator_detail[
    "first_7d_publish_cnt"
].fillna(1)
new_creator_detail["first_7d_avg_daily_posts"] = (
    new_creator_detail["first_7d_publish_cnt"] / 8
)

# 按首月+首篇赛道计算分位，保证不同批次的“高/低曝光”是相对同批创作者。
new_creator_detail["first_note_exposure_quintile"] = pd.NA
new_creator_detail["first_note_interaction_quintile"] = pd.NA
for _, group_index in new_creator_detail.groupby(
    ["cohort_month", "first_note_category"],
    dropna=False,
).groups.items():
    group = new_creator_detail.loc[group_index]
    new_creator_detail.loc[group_index, "first_note_exposure_quintile"] = (
        quantile_bucket(group["first_note_exposure_uv"], 5)
    )
    new_creator_detail.loc[group_index, "first_note_interaction_quintile"] = (
        quantile_bucket(group["first_note_interaction_rate"], 5)
    )

new_creator_detail["first_note_exposure_band"] = new_creator_detail[
    "first_note_exposure_quintile"
].apply(
    lambda value: (
        "低曝光" if pd.notna(value) and float(value) <= 2
        else "中曝光" if pd.notna(value) and float(value) == 3
        else "高曝光"
    )
)
new_creator_detail["first_note_interaction_band"] = new_creator_detail[
    "first_note_interaction_quintile"
].apply(
    lambda value: (
        "低互动" if pd.notna(value) and float(value) <= 2
        else "中互动" if pd.notna(value) and float(value) == 3
        else "高互动"
    )
)
new_creator_detail["first_note_segment"] = (
    new_creator_detail["first_note_exposure_band"]
    + "/"
    + new_creator_detail["first_note_interaction_band"]
)

new_segment_summary = (
    new_creator_detail.groupby(
        ["cohort_month", "first_note_category", "first_note_segment"],
        as_index=False,
    )
    .agg(
        creator_cnt=("creator_id", "count"),
        retention_7d_eligible_cnt=("retained_7d_eligible", "sum"),
        retained_7d_cnt=("retained_7d", lambda s: s.fillna(0).sum()),
        retention_14d_eligible_cnt=("retained_14d_eligible", "sum"),
        retained_14d_cnt=("retained_14d", lambda s: s.fillna(0).sum()),
        avg_first_note_exposure_uv=("first_note_exposure_uv", "mean"),
        avg_first_note_ctr=("first_note_ctr", "mean"),
        avg_first_note_interaction_rate=("first_note_interaction_rate", "mean"),
    )
)
new_segment_summary["retention_7d_rate"] = safe_divide(
    new_segment_summary["retained_7d_cnt"],
    new_segment_summary["retention_7d_eligible_cnt"],
)
new_segment_summary["retention_14d_rate"] = safe_divide(
    new_segment_summary["retained_14d_cnt"],
    new_segment_summary["retention_14d_eligible_cnt"],
)

print(
    "新人分群数="
    f"{new_creator_detail['first_note_segment'].nunique()}；"
    "分群统计已生成。"
)
print(
    new_segment_summary.sort_values(
        "creator_cnt",
        ascending=False,
    )
    .head(10)
    .to_string(index=False)
)

save_csv(
    new_creator_detail,
    "dws_new_creator_retention_detail.csv",
)
save_csv(
    new_segment_summary,
    "dws_new_creator_retention_segments.csv",
)


# =============================================================================
# 6. 内容赛道 DWS 汇总
# =============================================================================

print_section("6. 内容赛道 DWS 汇总")

note_track = note_core.merge(
    creator_dimension[
        ["creator_id", "creator_segment_3d", "is_new_creator"]
    ],
    on="creator_id",
    how="left",
    validate="many_to_one",
)
note_track["settled_revenue"] = note_track.apply(
    lambda row: (
        float(row.get("ad_revenue_30d") or 0)
        + float(row.get("commission_revenue_30d") or 0)
        if row.get("settlement_status") == "已结算"
        else 0.0
    ),
    axis=1,
)

track_summary = (
    note_track.groupby("content_category", dropna=False)
    .agg(
        active_creator_cnt=("creator_id", "nunique"),
        new_creator_cnt=(
            "creator_id",
            lambda s: s[
                note_track.loc[s.index, "is_new_creator"].fillna(0).eq(1)
            ].nunique(),
        ),
        valid_note_cnt=("note_id", "count"),
        exposure_uv_7d=("exposure_uv_7d", "sum"),
        click_uv_7d=("click_uv_7d", "sum"),
        positive_interaction_cnt=("interaction_cnt_7d", "sum"),
        product_click_uv_30d=("product_click_uv_30d", "sum"),
        paid_buyer_uv_30d=("paid_buyer_uv_30d", "sum"),
        net_gmv_30d=("net_gmv_30d", "sum"),
        settled_revenue=("settled_revenue", "sum"),
    )
    .reset_index()
)

track_new_retention = (
    new_creator_detail.groupby("first_note_category", as_index=False)
    .agg(
        retention_7d_eligible_cnt=("retained_7d_eligible", "sum"),
        retained_7d_cnt=("retained_7d", lambda s: s.fillna(0).sum()),
        retention_14d_eligible_cnt=("retained_14d_eligible", "sum"),
        retained_14d_cnt=("retained_14d", lambda s: s.fillna(0).sum()),
    )
    .rename(columns={"first_note_category": "content_category"})
)

track_summary = track_summary.merge(
    track_new_retention,
    on="content_category",
    how="left",
    validate="one_to_one",
)
track_summary["ctr"] = safe_divide(
    track_summary["click_uv_7d"],
    track_summary["exposure_uv_7d"],
)
track_summary["positive_interaction_rate"] = safe_divide(
    track_summary["positive_interaction_cnt"],
    track_summary["click_uv_7d"],
)
track_summary["commerce_conversion_rate"] = safe_divide(
    track_summary["paid_buyer_uv_30d"],
    track_summary["product_click_uv_30d"],
)
track_summary["revenue_per_note"] = safe_divide(
    track_summary["settled_revenue"],
    track_summary["valid_note_cnt"],
)
track_summary["revenue_per_1k_exposure"] = (
    safe_divide(track_summary["settled_revenue"], track_summary["exposure_uv_7d"])
    * 1000
)
track_summary["retention_7d_rate"] = safe_divide(
    track_summary["retained_7d_cnt"],
    track_summary["retention_7d_eligible_cnt"],
)
track_summary["retention_14d_rate"] = safe_divide(
    track_summary["retained_14d_cnt"],
    track_summary["retention_14d_eligible_cnt"],
)
track_summary["traffic_share"] = safe_divide(
    track_summary["exposure_uv_7d"],
    pd.Series(
        [track_summary["exposure_uv_7d"].sum()] * len(track_summary),
        index=track_summary.index,
    ),
)
track_summary["revenue_share"] = safe_divide(
    track_summary["settled_revenue"],
    pd.Series(
        [track_summary["settled_revenue"].sum()] * len(track_summary),
        index=track_summary.index,
    ),
)
track_summary = track_summary.sort_values(
    "exposure_uv_7d",
    ascending=False,
)

print(track_summary.to_string(index=False))
if not track_summary.empty:
    highest_ctr = track_summary.dropna(subset=["ctr"]).sort_values(
        "ctr", ascending=False
    ).head(1)
    highest_revenue = track_summary.sort_values(
        "revenue_per_note", ascending=False
    ).head(1)
    print(
        f"赛道观测：CTR最高={highest_ctr['content_category'].iloc[0] if len(highest_ctr) else '无数据'}；"
        f"单篇已结算收益最高={highest_revenue['content_category'].iloc[0] if len(highest_revenue) else '无数据'}。"
    )

save_csv(track_summary, "dws_track_summary.csv")


# =============================================================================
# 7. 新人 7 天留存成功组 vs 流失停更组：只做特征差异对比
# =============================================================================

print_section("7. 新人 7 天留存成功组与流失停更组特征差异")

new_comparison = new_creator_detail[
    new_creator_detail["retained_7d_eligible"].fillna(False)
].copy()
new_comparison["留存分组"] = new_comparison["retained_7d"].map(
    {1.0: "7天留存成功", 0.0: "7天流失停更"}
)

comparison_metrics = [
    "first_note_exposure_uv",
    "first_note_click_uv",
    "first_note_ctr",
    "first_note_interaction_cnt",
    "first_note_interaction_rate",
    "first_7d_publish_cnt",
    "first_7d_avg_daily_posts",
]

comparison_summary = (
    new_comparison.groupby("留存分组")[comparison_metrics]
    .agg(["count", "mean", "median"])
    .reset_index()
)
comparison_summary.columns = [
    "_".join(col).strip("_") if isinstance(col, tuple) else col
    for col in comparison_summary.columns
]

track_group_distribution = pd.crosstab(
    new_comparison["first_note_category"],
    new_comparison["留存分组"],
    normalize="columns",
).reset_index()

print(comparison_summary.to_string(index=False))
print("\n赛道分布（按留存组内占比）：")
print(track_group_distribution.to_string(index=False))

save_csv(comparison_summary, "new_creator_7d_group_comparison.csv")
save_csv(track_group_distribution, "new_creator_7d_track_distribution.csv")


# =============================================================================
# 8. 可视化：四张高清图片，全部保存，不调用 plt.show()
# =============================================================================

print_section("8. 可视化输出")

setup_plot_style()

# -----------------------------------------------------------------------------
# 图1：新人 7/14 天累计再发文留存曲线
# 业务解读：采用 D14 已成熟新人固定分母，展示首篇后第1-14天是否出现再次发文。
# -----------------------------------------------------------------------------
d14_mature_new = new_creator_detail[
    new_creator_detail["retained_14d_eligible"].fillna(False)
].copy()
d14_ids = set(d14_mature_new["creator_id"])
note_retention_activity = note_with_first[
    note_with_first["creator_id"].isin(d14_ids)
    & note_with_first["days_since_first"].between(1, 14)
][["creator_id", "days_since_first"]].copy()

retention_presence = pd.DataFrame(
    False,
    index=sorted(d14_ids),
    columns=range(1, 15),
)
if not note_retention_activity.empty:
    note_retention_activity["days_since_first"] = (
        note_retention_activity["days_since_first"].astype(int)
    )
    for row in note_retention_activity.itertuples(index=False):
        retention_presence.loc[row.creator_id, row.days_since_first] = True

retention_presence = retention_presence.cummax(axis=1)
retention_curve = retention_presence.mean(axis=0)

fig, ax = plt.subplots(figsize=(9, 5.5))
ax.plot(
    retention_curve.index,
    retention_curve.values * 100,
    marker="o",
    linewidth=2.5,
    color="#2563EB",
)
ax.axvline(7, linestyle="--", color="#F59E0B", alpha=0.8)
ax.axvline(14, linestyle="--", color="#DC2626", alpha=0.8)
ax.scatter(
    [7],
    [retention_curve.loc[7] * 100],
    s=90,
    color="#F59E0B",
    zorder=4,
)
ax.scatter(
    [14],
    [retention_curve.loc[14] * 100],
    s=90,
    color="#DC2626",
    zorder=4,
)
ax.text(
    7,
    retention_curve.loc[7] * 100 + 2,
    f"D7 {retention_curve.loc[7]:.1%}",
    ha="center",
    color="#92400E",
)
ax.text(
    14,
    retention_curve.loc[14] * 100 + 2,
    f"D14 {retention_curve.loc[14]:.1%}",
    ha="center",
    color="#991B1B",
)
ax.set_title("新人创作者首篇后累计再发文留存曲线")
ax.set_xlabel("首篇有效笔记后的天数")
ax.set_ylabel("累计留存率（%）")
ax.set_xticks(range(1, 15))
ax.set_ylim(
    0,
    min(100, max(10, retention_curve.max() * 100 + 8)),
)
add_figure_caption(
    fig,
    "业务解读：留存按“是否再次发布有效公开笔记”定义，不是登录留存；"
    "曲线使用D14已成熟新人固定分母。",
)
fig.tight_layout(rect=(0, 0.06, 1, 1))
fig.savefig(OUTPUT_DIR / "01_new_creator_retention_curve.png", bbox_inches="tight")
plt.close(fig)

# -----------------------------------------------------------------------------
# 图2：赛道点击率与单篇收益散点图
# 业务解读：横轴为点击效率，纵轴为单篇已结算创作者收益，气泡大小表示笔记量。
# -----------------------------------------------------------------------------
plot_track = track_summary.dropna(subset=["ctr", "revenue_per_note"]).copy()
fig, ax = plt.subplots(figsize=(10, 6.2))
if not plot_track.empty:
    sns.scatterplot(
        data=plot_track,
        x=plot_track["ctr"] * 100,
        y="revenue_per_note",
        size="valid_note_cnt",
        sizes=(120, 1300),
        hue="content_category",
        palette="Set2",
        legend=False,
        alpha=0.82,
        ax=ax,
    )
    for row in plot_track.itertuples(index=False):
        ax.annotate(
            row.content_category,
            (row.ctr * 100, row.revenue_per_note),
            xytext=(5, 5),
            textcoords="offset points",
            fontsize=9,
        )
ax.set_title("内容赛道点击率与单篇变现收益")
ax.set_xlabel("7日点击率 CTR（%）")
ax.set_ylabel("单篇已结算创作者收益（元）")
ax.grid(alpha=0.3)
add_figure_caption(
    fig,
    "业务解读：点击率反映内容消费效率，单篇收益反映已结算变现效率；"
    "气泡大小表示有效笔记数，不等同于平台毛利。",
)
fig.tight_layout(rect=(0, 0.07, 1, 1))
fig.savefig(OUTPUT_DIR / "02_track_ctr_revenue_scatter.png", bbox_inches="tight")
plt.close(fig)

# -----------------------------------------------------------------------------
# 图3：三维分层人数分布
# 业务解读：展示四组当前规模和优先级，阈值来自本次数据分位数。
# -----------------------------------------------------------------------------
segment_order = ["潜力新人", "腰部稳定", "头部高收益", "低价值流失群体"]
segment_counts = (
    creator_dimension["creator_segment_3d"]
    .value_counts()
    .reindex(segment_order, fill_value=0)
)
fig, ax = plt.subplots(figsize=(9, 5.4))
bars = ax.bar(
    segment_counts.index,
    segment_counts.values,
    color=["#60A5FA", "#34D399", "#F59E0B", "#9CA3AF"],
)
for bar, value in zip(bars, segment_counts.values):
    ax.text(
        bar.get_x() + bar.get_width() / 2,
        bar.get_height() + max(segment_counts.max() * 0.01, 1),
        f"{value:,}\n({value / max(len(creator_dimension), 1):.1%})",
        ha="center",
        va="bottom",
        fontsize=9,
    )
ax.set_title("创作者三维分层人数分布")
ax.set_xlabel("创作者分层")
ax.set_ylabel("创作者人数")
ax.set_ylim(0, segment_counts.max() * 1.2 + 1)
add_figure_caption(
    fig,
    "业务解读：分层依据活跃度、流量效率和变现价值的分位数，"
    "不是RFM；相邻快照的绝对人数可能随创作者周期变化。",
)
fig.tight_layout(rect=(0, 0.07, 1, 1))
fig.savefig(OUTPUT_DIR / "03_creator_segment_distribution.png", bbox_inches="tight")
plt.close(fig)

# -----------------------------------------------------------------------------
# 图4：留存成功 vs 流失停更新人的首篇关键指标箱线图
# 业务解读：只展示观测差异，不据此声称因果关系；曝光使用对数轴减少极端值影响。
# -----------------------------------------------------------------------------
boxplot_metrics = [
    ("first_note_exposure_uv", "首篇曝光UV", True),
    ("first_note_ctr", "首篇点击率", False),
    ("first_note_interaction_rate", "首篇互动率", False),
    ("first_7d_publish_cnt", "首篇后7日发布篇数", False),
]
fig, axes = plt.subplots(2, 2, figsize=(12, 8.4))
for axis, (column, label, use_log) in zip(axes.flatten(), boxplot_metrics):
    sns.boxplot(
        data=new_comparison,
        x="留存分组",
        y=column,
        showfliers=False,
        palette=["#FCA5A5", "#93C5FD"],
        ax=axis,
    )
    sns.stripplot(
        data=new_comparison.sample(
            min(len(new_comparison), 1200),
            random_state=42,
        ),
        x="留存分组",
        y=column,
        size=1.4,
        alpha=0.25,
        color="#374151",
        ax=axis,
    )
    if use_log:
        axis.set_yscale("log")
    axis.set_title(label)
    axis.set_xlabel("")
    axis.set_ylabel(label)
fig.suptitle("新人7天留存成功组与流失停更组的首篇表现差异", fontsize=14)
add_figure_caption(
    fig,
    "业务解读：箱线图仅描述两组观测差异，不能识别因果；"
    "曝光采用对数轴，离群点不显示但未删除。",
)
fig.tight_layout(rect=(0, 0.06, 1, 0.95))
fig.savefig(OUTPUT_DIR / "04_new_creator_boxplot.png", bbox_inches="tight")
plt.close(fig)

print("四张图片已保存到 output 目录。")


# =============================================================================
# 9. 中间分析结论：严格区分观测现象和主观猜想，不输出策略
# =============================================================================

print_section("9. 中间分析结论")

segment_counts_full = creator_dimension["creator_segment_3d"].value_counts()
retained_group = new_comparison[new_comparison["retained_7d"].eq(1)]
churned_group = new_comparison[new_comparison["retained_7d"].eq(0)]

def median_or_nan(data: pd.DataFrame, column: str) -> float:
    """返回安全中位数，供结论文本使用。"""
    if data.empty:
        return float("nan")
    return float(data[column].median())


retained_exposure_median = median_or_nan(retained_group, "first_note_exposure_uv")
churned_exposure_median = median_or_nan(churned_group, "first_note_exposure_uv")
retained_ctr_median = median_or_nan(retained_group, "first_note_ctr")
churned_ctr_median = median_or_nan(churned_group, "first_note_ctr")
retained_interaction_median = median_or_nan(
    retained_group,
    "first_note_interaction_rate",
)
churned_interaction_median = median_or_nan(
    churned_group,
    "first_note_interaction_rate",
)

observation_lines = [
    f"1. ODS 笔记 {len(note_raw):,} 行全部保留在 DWD；"
    f"DWD 中 is_core_eligible=1 的笔记为 {len(note_core):,} 行。",
    f"2. 新人创作者 {len(new_creator_lifecycle):,} 人；"
    f"D7 可评估 {len(d7_eligible):,} 人，D7 再次发布留存率 {d7_rate:.2%}；"
    f"D14 可评估 {len(d14_eligible):,} 人，D14 累计再次发布留存率 {d14_rate:.2%}。",
    "3. 7天留存成功组首篇曝光中位数为"
    f" {retained_exposure_median:,.0f}，"
    "7天流失停更组为"
    f" {churned_exposure_median:,.0f}；"
    f"两组首篇CTR中位数分别为 {retained_ctr_median:.2%} 和 {churned_ctr_median:.2%}，"
    f"首篇互动率中位数分别为 {retained_interaction_median:.2%} 和 {churned_interaction_median:.2%}。",
    "4. 三维分层人数：" + "；".join(
        f"{segment} {segment_counts_full.get(segment, 0):,} 人"
        for segment in segment_order
    ) + "。",
    "5. 赛道汇总共 "
    f"{len(track_summary):,} 个类目；"
    "赛道比较同时包含创作者规模、有效曝光、CTR、互动、成交、"
    "已结算收益和新人 D7/D14 留存。",
]

conjecture_lines = [
    "1. 首篇曝光较低与后续停更存在同向观测差异，但本环节没有识别因果，"
    "不能排除赛道、内容质量和账号基础带来的混杂。",
    "2. 三维分层中的“潜力新人”来自相对分位规则，"
    "并不等于经过实验验证的可提升人群。",
    "3. 单篇变现收益只使用已结算创作者收益；"
    "缺少成本字段，不能解释为平台毛利。",
]

conclusion_text = "\n".join(
    [
        "【观测现象】",
        *observation_lines,
        "",
        "【主观猜想（未验证）】",
        *conjecture_lines,
        "",
        "【边界说明】",
        "以上结论不含运营或产品策略建议，策略判断留待后续实验与归因环节。",
    ]
)

print(conclusion_text)
(OUTPUT_DIR / "analysis_summary.txt").write_text(
    conclusion_text,
    encoding="utf-8",
)

print("\n全部处理完成。")
print("请查看 output 目录中的：")
print("  - dwd_note_mid.csv")
print("  - dwd_creator_mid.csv")
print("  - dws_creator_lifecycle.csv")
print("  - dws_new_creator_retention_detail.csv")
print("  - dws_new_creator_retention_segments.csv")
print("  - dws_track_summary.csv")
print("  - creator_three_dim_segments.csv")
print("  - 4张PNG")
print("  - analysis_summary.txt")
