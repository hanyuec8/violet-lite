// This source code is a part of Project Violet.
// Copyright (C) 2020-2026. violet-team. Licensed under the Apache-2.0 License.

//! Native HTML DOM parser for E-Hentai/ExHentai and Hitomi.la pages using `scraper`.

use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::LazyLock;

use scraper::{ElementRef, Html, Selector};

#[derive(Debug, Clone)]
pub struct HitomiGalleryBlockParsed {
    pub magic: Option<String>,
    pub thumbnail: Option<String>,
    pub title: String,
    pub artists: Vec<String>,
    pub series: Vec<String>,
    pub article_type: Option<String>,
    pub language: Option<String>,
    pub tags: Vec<String>,
    pub published: Option<String>,
}

#[derive(Debug, Clone)]
pub struct HitomiGalleryExtraParsed {
    pub groups: Vec<String>,
    pub characters: Vec<String>,
}

#[derive(Debug, Clone)]
pub struct EhResultArticleParsed {
    pub url: Option<String>,
    pub thumbnail: Option<String>,
    pub title: Option<String>,
    pub uploader: Option<String>,
    pub published: Option<String>,
    pub files: Option<String>,
    pub article_type: Option<String>,
    pub descript_keys: Vec<String>,
    pub descript_values: Vec<Vec<String>>,
}

#[derive(Debug, Clone)]
pub struct EhCommentParsed {
    pub posted_raw: String,
    pub author: String,
    pub contents: String,
}

#[derive(Debug, Clone)]
pub struct EhArticleParsed {
    pub thumbnail: String,
    pub images_per_page: i32,
    pub title: String,
    pub sub_title: String,
    pub uploader: Option<String>,
    pub posted: String,
    pub parent: String,
    pub visible: String,
    pub language: String,
    pub file_size: String,
    pub length: i32,
    pub favorited: i32,
    pub languages: Option<Vec<String>>,
    pub group: Option<Vec<String>>,
    pub parody: Option<Vec<String>>,
    pub character: Option<Vec<String>>,
    pub artist: Option<Vec<String>>,
    pub male: Option<Vec<String>>,
    pub female: Option<Vec<String>>,
    pub misc: Option<Vec<String>>,
    pub comments: Vec<EhCommentParsed>,
}

fn sel(css: &str) -> Selector {
    Selector::parse(css).expect("static CSS selector must be valid")
}

#[inline]
fn el_text(el: ElementRef<'_>) -> String {
    el.text().collect::<String>()
}

#[inline]
fn el_text_trimmed(el: ElementRef<'_>) -> String {
    el_text(el).trim().to_string()
}

fn parse_hitomi_thumbnail(doc: ElementRef<'_>) -> Option<String> {
    static S_IMG: LazyLock<Selector> = LazyLock::new(|| sel("a img"));
    let img = doc.select(&S_IMG).next()?;
    let value = img
        .value()
        .attr("data-src")
        .or_else(|| img.value().attr("src"))?;
    if value.is_empty() {
        return None;
    }
    const PREFIX: &str = "//tn.gold-usergeneratedcontent.net/";
    if let Some(rest) = value.strip_prefix(PREFIX) {
        Some(rest.replacen("smallbig", "big", 1))
    } else {
        Some(value.to_string())
    }
}

fn legalize_hitomi_language(language: Option<&str>) -> Option<String> {
    let raw = language?.trim();
    if raw.is_empty() {
        return None;
    }
    let mapped = match raw {
        "모든 언어" => "all",
        "한국어" => "korean",
        "N/A" => "n/a",
        "日本語" => "japanese",
        "English" => "english",
        "Español" => "spanish",
        "ไทย" => "thai",
        "Deutsch" => "german",
        "中文" => "chinese",
        "Português" => "portuguese",
        "Français" => "french",
        "Tagalog" => "tagalog",
        "Русский" => "russian",
        "Italiano" => "italian",
        "polski" => "polish",
        "tiếng việt" => "vietnamese",
        "magyar" => "hungarian",
        "Čeština" => "czech",
        "Bahasa Indonesia" => "indonesian",
        "العربية" => "arabic",
        _ => return Some(raw.to_lowercase()),
    };
    Some(mapped.to_string())
}

fn normalize_hitomi_tag(tag: &str, suffix: &str) -> String {
    let trimmed = if suffix.is_empty() {
        tag
    } else {
        tag.strip_suffix(suffix).unwrap_or(tag).trim()
    };
    trimmed.to_lowercase().replace(' ', "_")
}

fn legalize_hitomi_tag(tag: &str) -> String {
    let value = tag.trim();
    if value.ends_with('♀') {
        format!("female:{}", normalize_hitomi_tag(value, "♀"))
    } else if value.ends_with('♂') {
        format!("male:{}", normalize_hitomi_tag(value, "♂"))
    } else {
        normalize_hitomi_tag(value, "")
    }
}

fn parse_links_from_label(rows: &[ElementRef<'_>], label: &str) -> Vec<String> {
    static S_TD: LazyLock<Selector> = LazyLock::new(|| sel("td"));
    static S_A: LazyLock<Selector> = LazyLock::new(|| sel("a"));

    for row in rows {
        let mut tds = row.select(&S_TD);
        let Some(first_td) = tds.next() else {
            continue;
        };
        if el_text(first_td).trim().to_lowercase() != label {
            continue;
        }
        let Some(second_td) = tds.next() else {
            return Vec::new();
        };
        return second_td
            .select(&S_A)
            .map(el_text_trimmed)
            .filter(|s| !s.is_empty())
            .collect();
    }
    Vec::new()
}

pub(crate) fn parse_hitomi_gallery_block_inner(
    html: &str,
) -> Result<HitomiGalleryBlockParsed, String> {
    static S_DIV: LazyLock<Selector> = LazyLock::new(|| sel("div"));
    static S_H1: LazyLock<Selector> = LazyLock::new(|| sel("h1"));
    static S_A: LazyLock<Selector> = LazyLock::new(|| sel("a"));
    static S_ARTIST_1: LazyLock<Selector> = LazyLock::new(|| sel("div.artist-list li a"));
    static S_ARTIST_2: LazyLock<Selector> = LazyLock::new(|| sel("div.artists-list li a"));
    static S_TABLE: LazyLock<Selector> = LazyLock::new(|| sel("table"));
    static S_TR: LazyLock<Selector> = LazyLock::new(|| sel("table tr"));
    static S_P_DATE: LazyLock<Selector> = LazyLock::new(|| sel("p.date"));
    static S_DOT_DATE: LazyLock<Selector> = LazyLock::new(|| sel(".date"));
    static S_P: LazyLock<Selector> = LazyLock::new(|| sel("p"));

    let parsed = Html::parse_document(html);
    let doc = parsed
        .select(&S_DIV)
        .next()
        .ok_or_else(|| "missing root div in galleryblock".to_string())?;

    let title = doc
        .select(&S_H1)
        .next()
        .map(el_text_trimmed)
        .ok_or_else(|| "missing h1 title in galleryblock".to_string())?;

    let magic = doc
        .select(&S_A)
        .next()
        .and_then(|a| a.value().attr("href"))
        .map(str::to_string);

    let thumbnail = parse_hitomi_thumbnail(doc);

    let mut artists: Vec<String> = doc.select(&S_ARTIST_1).map(el_text_trimmed).collect();
    if artists.is_empty() {
        artists = doc.select(&S_ARTIST_2).map(el_text_trimmed).collect();
    }
    if artists.is_empty() {
        artists = vec!["N/A".to_string()];
    }

    let child_divs: Vec<ElementRef<'_>> = doc
        .children()
        .filter_map(ElementRef::wrap)
        .filter(|el| el.value().name().eq_ignore_ascii_case("div"))
        .collect();
    let metadata_el = if child_divs.len() > 1 {
        Some(child_divs[1])
    } else {
        doc.select(&S_TABLE)
            .next()
            .and_then(|tbl| tbl.parent().and_then(ElementRef::wrap))
    };

    let rows: Vec<ElementRef<'_>> = metadata_el
        .map(|m| m.select(&S_TR).collect())
        .unwrap_or_default();

    let series = parse_links_from_label(&rows, "series");
    let article_type = parse_links_from_label(&rows, "type").into_iter().next();
    let lang_first = parse_links_from_label(&rows, "language")
        .into_iter()
        .next();
    let language = legalize_hitomi_language(lang_first.as_deref());

    let parsed_tags = parse_links_from_label(&rows, "tags");
    let raw_tags = if parsed_tags.is_empty() {
        parse_links_from_label(&rows, "tag")
    } else {
        parsed_tags
    };
    let tags = raw_tags.iter().map(|t| legalize_hitomi_tag(t)).collect();

    let published = doc
        .select(&S_P_DATE)
        .next()
        .map(el_text_trimmed)
        .or_else(|| doc.select(&S_DOT_DATE).next().map(el_text_trimmed))
        .or_else(|| {
            metadata_el
                .and_then(|m| m.select(&S_P).next())
                .map(el_text_trimmed)
        });

    Ok(HitomiGalleryBlockParsed {
        magic,
        thumbnail,
        title,
        artists,
        series,
        article_type,
        language,
        tags,
        published,
    })
}

/// Hitomi galleryblock HTML을 백그라운드 스레드에서 파싱합니다.
pub fn parse_hitomi_gallery_block(html: String) -> Result<HitomiGalleryBlockParsed, String> {
    parse_hitomi_gallery_block_inner(&html)
}

/// Hitomi 갤러리 상세 HTML에서 그룹·캐릭터 목록을 추출합니다.
pub fn parse_hitomi_gallery(html: String) -> HitomiGalleryExtraParsed {
    static S_TR: LazyLock<Selector> = LazyLock::new(|| sel("div.gallery-info table tr"));
    static S_TD: LazyLock<Selector> = LazyLock::new(|| sel("td"));
    static S_A: LazyLock<Selector> = LazyLock::new(|| sel("a"));

    let parsed = Html::parse_document(&html);
    let mut groups = Vec::new();
    let mut characters = Vec::new();

    for tr in parsed.select(&S_TR) {
        let Some(key_el) = tr.select(&S_TD).next() else {
            continue;
        };
        let key = el_text(key_el).trim().to_lowercase();
        let values: Vec<String> = tr
            .select(&S_A)
            .map(el_text_trimmed)
            .filter(|s| !s.is_empty())
            .collect();
        if key == "group" || key == "groups" {
            groups = values;
        } else if key == "character" || key == "characters" {
            characters = values;
        }
    }

    HitomiGalleryExtraParsed { groups, characters }
}

fn parse_eh_images_url_inner(html: &str) -> Vec<String> {
    static S_GDT: LazyLock<Selector> = LazyLock::new(|| sel("div[id='gdt']"));
    static S_DIV: LazyLock<Selector> = LazyLock::new(|| sel("div"));
    static S_A: LazyLock<Selector> = LazyLock::new(|| sel("a"));

    let parsed = Html::parse_document(html);
    let Some(doc) = parsed.select(&S_GDT).next() else {
        return Vec::new();
    };
    let mut result = Vec::new();
    let mut seen = HashSet::new();

    for div in doc.select(&S_DIV) {
        if let Some(a) = div.select(&S_A).next() {
            if let Some(href) = a.value().attr("href") {
                if seen.insert(href.to_string()) {
                    result.push(href.to_string());
                }
            }
        }
    }
    for a in doc.select(&S_A) {
        if let Some(href) = a.value().attr("href") {
            if seen.insert(href.to_string()) {
                result.push(href.to_string());
            }
        }
    }
    result
}

#[flutter_rust_bridge::frb(sync)]
pub fn parse_eh_images_url_sync(html: String) -> Vec<String> {
    parse_eh_images_url_inner(&html)
}

fn parse_eh_image_address_inner(html: &str) -> Result<String, String> {
    static S_I1_IMG: LazyLock<Selector> = LazyLock::new(|| sel("div[id='i1'] div[id='i3'] a img"));
    let parsed = Html::parse_document(html);
    parsed
        .select(&S_I1_IMG)
        .next()
        .and_then(|img| img.value().attr("src"))
        .map(str::to_string)
        .ok_or_else(|| "image src not found".to_string())
}

#[flutter_rust_bridge::frb(sync)]
pub fn parse_eh_image_address_sync(html: String) -> Result<String, String> {
    parse_eh_image_address_inner(&html)
}

fn extract_eh_thumbnail_from_style(style: &str) -> Option<String> {
    for prefix in ["https://s.exhentai.org/", "https://s.ehgt.org/", "https://exhentai.org/", "https://ehgt.org/"] {
        if let Some(start) = style.find(prefix) {
            let tail = &style[start..];
            let end = tail.find(')').unwrap_or(tail.len());
            return Some(tail[..end].to_string());
        }
    }
    None
}

fn parse_images_per_page(text: &str) -> Result<i32, String> {
    let dash = text
        .find('-')
        .ok_or_else(|| "missing '-' in gpc".to_string())?;
    let of_pos = text[dash + 1..]
        .find("of")
        .ok_or_else(|| "missing 'of' in gpc".to_string())?;

    let first_part = text[..dash].trim();
    let first_digits: String = first_part
        .chars()
        .rev()
        .take_while(|c| c.is_ascii_digit())
        .collect::<String>()
        .chars()
        .rev()
        .collect();
    let second_part = text[dash + 1..dash + 1 + of_pos].trim();
    let second_digits: String = second_part
        .chars()
        .take_while(|c| c.is_ascii_digit())
        .collect();

    let first_num = first_digits
        .parse::<i32>()
        .map_err(|_| "invalid first gpc index".to_string())?;
    let second_num = second_digits
        .parse::<i32>()
        .map_err(|_| "invalid last gpc index".to_string())?;
    Ok(second_num - (first_num - 1))
}

fn replace_br_with_crlf_and_decode(inner_html: &str) -> String {
    let replaced = inner_html
        .replace("<br>", "\r\n")
        .replace("<br/>", "\r\n")
        .replace("<br />", "\r\n")
        .replace("<BR>", "\r\n");
    let frag = Html::parse_fragment(&replaced);
    frag.root_element().text().collect::<String>()
}

fn parse_eh_article_data_inner(html: &str) -> Result<EhArticleParsed, String> {
    static S_GM: LazyLock<Selector> = LazyLock::new(|| sel("div.gm"));
    static S_THUMB: LazyLock<Selector> = LazyLock::new(|| sel("div[id='gleft'] div div"));
    static S_GPC: LazyLock<Selector> = LazyLock::new(|| sel(".gtb > .gpc"));
    static S_GN: LazyLock<Selector> = LazyLock::new(|| sel("div[id='gd2'] h1[id='gn']"));
    static S_GJ: LazyLock<Selector> = LazyLock::new(|| sel("div[id='gd2'] h1[id='gj']"));
    static S_GDN: LazyLock<Selector> = LazyLock::new(|| sel("div[id='gmid'] div[id='gdn']"));
    static S_GDD_TR: LazyLock<Selector> =
        LazyLock::new(|| sel("div[id='gmid'] div[id='gdd'] table tr"));
    static S_GDT2: LazyLock<Selector> = LazyLock::new(|| sel("td.gdt2"));
    static S_TAG_TR: LazyLock<Selector> =
        LazyLock::new(|| sel("div[id='gmid'] div[id='taglist'] table tr"));
    static S_TD: LazyLock<Selector> = LazyLock::new(|| sel("td"));
    static S_DIV_A: LazyLock<Selector> = LazyLock::new(|| sel("div a"));
    static S_C1: LazyLock<Selector> = LazyLock::new(|| sel("div[id='cdiv'] > div.c1"));
    static S_C3: LazyLock<Selector> = LazyLock::new(|| sel("div.c2 div.c3"));
    static S_C3_A: LazyLock<Selector> = LazyLock::new(|| sel("div.c2 div.c3 > a"));
    static S_C4: LazyLock<Selector> = LazyLock::new(|| sel("div.c4.nosel"));
    static S_C6: LazyLock<Selector> = LazyLock::new(|| sel("div.c6"));

    let parsed = Html::parse_document(html);
    let doc = parsed
        .select(&S_GM)
        .next()
        .ok_or_else(|| "missing div.gm".to_string())?;

    let style = doc
        .select(&S_THUMB)
        .next()
        .and_then(|el| el.value().attr("style"))
        .ok_or_else(|| "missing thumbnail style".to_string())?;
    let thumbnail = extract_eh_thumbnail_from_style(style)
        .unwrap_or_else(|| "null".to_string());

    let gpc_text = parsed
        .select(&S_GPC)
        .next()
        .map(el_text)
        .ok_or_else(|| "missing .gtb > .gpc".to_string())?;
    let images_per_page = parse_images_per_page(&gpc_text)?;

    let title = doc
        .select(&S_GN)
        .next()
        .map(el_text)
        .ok_or_else(|| "missing #gn".to_string())?;
    let sub_title = doc
        .select(&S_GJ)
        .next()
        .map(el_text)
        .ok_or_else(|| "missing #gj".to_string())?;
    let uploader = doc.select(&S_GDN).next().map(el_text);

    let gdd_rows: Vec<ElementRef<'_>> = doc.select(&S_GDD_TR).collect();
    if gdd_rows.len() < 7 {
        return Err("insufficient #gdd rows".to_string());
    }
    let gdt2_text = |idx: usize| -> Result<String, String> {
        gdd_rows[idx]
            .select(&S_GDT2)
            .next()
            .map(el_text)
            .ok_or_else(|| format!("missing td.gdt2 at row {idx}"))
    };

    let posted = gdt2_text(0)?;
    let parent = gdt2_text(1)?;
    let visible = gdt2_text(2)?;
    let language = gdt2_text(3)?;
    let file_size = gdt2_text(4)?;
    let length = gdt2_text(5)?
        .replace("pages", "")
        .trim()
        .parse::<i32>()
        .map_err(|e| format!("invalid page length: {e}"))?;
    let favorited = gdt2_text(6)?
        .replace("times", "")
        .replace("Once", "1")
        .trim()
        .parse::<i32>()
        .map_err(|e| format!("invalid favorited count: {e}"))?;

    let mut info: HashMap<String, Vec<String>> = HashMap::new();
    for tr in doc.select(&S_TAG_TR) {
        let mut tds = tr.select(&S_TD);
        let Some(td0) = tds.next() else { continue };
        let Some(td1) = tds.next() else { continue };
        let key = el_text_trimmed(td0);
        let vals: Vec<String> = td1.select(&S_DIV_A).map(el_text).collect();
        info.insert(key, vals);
    }

    let mut comments = Vec::new();
    for c1 in parsed.select(&S_C1) {
        let Some(c3_el) = c1.select(&S_C3).next() else {
            continue;
        };
        let posted_raw = el_text_trimmed(c3_el);
        let author = if let Some(a) = c1.select(&S_C3_A).next() {
            el_text_trimmed(a)
        } else if c1
            .select(&S_C4)
            .next()
            .is_some_and(|el| el_text_trimmed(el) == "Uploader Comment")
        {
            uploader.as_deref().unwrap_or("").trim().to_string()
        } else {
            String::new()
        };
        let Some(c6_el) = c1.select(&S_C6).next() else {
            continue;
        };
        let contents = replace_br_with_crlf_and_decode(&c6_el.inner_html());
        comments.push(EhCommentParsed {
            posted_raw,
            author,
            contents,
        });
    }

    Ok(EhArticleParsed {
        thumbnail,
        images_per_page,
        title,
        sub_title,
        uploader,
        posted,
        parent,
        visible,
        language,
        file_size,
        length,
        favorited,
        languages: info.remove("language:"),
        group: info.remove("group:"),
        parody: info.remove("parody:"),
        character: info.remove("character:"),
        artist: info.remove("artist:"),
        male: info.remove("male:"),
        female: info.remove("female:"),
        misc: info.remove("misc:"),
        comments,
    })
}

#[flutter_rust_bridge::frb(sync)]
pub fn parse_eh_article_data_sync(html: String) -> Result<EhArticleParsed, String> {
    parse_eh_article_data_inner(&html)
}

pub fn parse_eh_article_data(html: String) -> Result<EhArticleParsed, String> {
    parse_eh_article_data_inner(&html)
}

fn parse_eh_thumbnail_view_inner(html: &str) -> Vec<EhResultArticleParsed> {
    static S_ITEM: LazyLock<Selector> = LazyLock::new(|| sel("div.itg > div.id1"));
    static S_ID2_A: LazyLock<Selector> = LazyLock::new(|| sel("div.id2 a"));
    static S_ID3_IMG: LazyLock<Selector> = LazyLock::new(|| sel("div.id3 a img"));
    static S_ID42: LazyLock<Selector> = LazyLock::new(|| sel("div.id42"));
    static S_ID41: LazyLock<Selector> = LazyLock::new(|| sel("div.id41"));

    let parsed = Html::parse_document(html);
    let mut result = Vec::new();
    for el in parsed.select(&S_ITEM) {
        let Some(id2_a) = el.select(&S_ID2_A).next() else {
            continue;
        };
        let Some(href) = id2_a.value().attr("href") else {
            continue;
        };
        let Some(id42) = el.select(&S_ID42).next() else {
            continue;
        };
        let Some(id41) = el.select(&S_ID41).next() else {
            continue;
        };
        result.push(EhResultArticleParsed {
            url: Some(href.to_string()),
            thumbnail: el
                .select(&S_ID3_IMG)
                .next()
                .and_then(|i| i.value().attr("src"))
                .map(str::to_string),
            title: Some(el_text(id2_a)),
            uploader: None,
            published: None,
            files: Some(el_text(id42)),
            article_type: id41.value().attr("title").map(str::to_string),
            descript_keys: Vec::new(),
            descript_values: Vec::new(),
        });
    }
    result
}

#[flutter_rust_bridge::frb(sync)]
pub fn parse_eh_thumbnail_view_sync(html: String) -> Vec<EhResultArticleParsed> {
    parse_eh_thumbnail_view_inner(&html)
}

fn parse_eh_list_view_inner(html: &str) -> Vec<EhResultArticleParsed> {
    static S_TR: LazyLock<Selector> = LazyLock::new(|| sel("div.itg > tr"));
    static S_TD: LazyLock<Selector> = LazyLock::new(|| sel("td"));
    static S_IT5_A: LazyLock<Selector> = LazyLock::new(|| sel("div.it5 a"));
    static S_IT2_IMG: LazyLock<Selector> = LazyLock::new(|| sel("div.it2 img"));
    static S_DIV_A: LazyLock<Selector> = LazyLock::new(|| sel("div > a"));
    static S_A_IMG: LazyLock<Selector> = LazyLock::new(|| sel("a img"));

    let parsed = Html::parse_document(html);
    let mut nodes: Vec<ElementRef<'_>> = parsed.select(&S_TR).collect();
    if nodes.len() > 1 {
        nodes.remove(0);
    }

    let mut result = Vec::new();
    for el in nodes {
        let tds: Vec<ElementRef<'_>> = el.select(&S_TD).collect();
        if tds.len() < 4 {
            continue;
        }
        let Some(it5_a) = tds[2].select(&S_IT5_A).next() else {
            continue;
        };
        let Some(href) = it5_a.value().attr("href") else {
            continue;
        };
        let Some(up_a) = tds[3].select(&S_DIV_A).next() else {
            continue;
        };
        let Some(up_href) = up_a.value().attr("href") else {
            continue;
        };
        let Some(type_img) = tds[0].select(&S_A_IMG).next() else {
            continue;
        };
        result.push(EhResultArticleParsed {
            url: Some(href.to_string()),
            thumbnail: tds[2]
                .select(&S_IT2_IMG)
                .next()
                .and_then(|i| i.value().attr("src"))
                .map(str::to_string),
            title: Some(el_text(it5_a)),
            uploader: Some(up_href.to_string()),
            published: Some(el_text(tds[1])),
            files: None,
            article_type: type_img.value().attr("alt").map(str::to_string),
            descript_keys: Vec::new(),
            descript_values: Vec::new(),
        });
    }
    result
}

#[flutter_rust_bridge::frb(sync)]
pub fn parse_eh_list_view_sync(html: String) -> Vec<EhResultArticleParsed> {
    parse_eh_list_view_inner(&html)
}

fn parse_eh_extended_list_view_inner(html: &str) -> Vec<EhResultArticleParsed> {
    static S_TABLE: LazyLock<Selector> = LazyLock::new(|| sel("table.itg.glte"));
    static S_A: LazyLock<Selector> = LazyLock::new(|| sel("a"));
    static S_IMG: LazyLock<Selector> = LazyLock::new(|| sel("img"));
    static S_TD: LazyLock<Selector> = LazyLock::new(|| sel("td"));
    static S_DIV_DIV: LazyLock<Selector> = LazyLock::new(|| sel("div > div"));
    static S_DIV: LazyLock<Selector> = LazyLock::new(|| sel("div"));
    static S_DIV_A_DIV: LazyLock<Selector> = LazyLock::new(|| sel("div > a > div"));
    static S_DIV_TABLE_TR: LazyLock<Selector> = LazyLock::new(|| sel("div > table tr"));
    static S_TR: LazyLock<Selector> = LazyLock::new(|| sel("tr"));

    let parsed = Html::parse_document(html);
    let mut queue: VecDeque<ElementRef<'_>> = parsed.select(&S_TABLE).collect();
    let mut result = Vec::new();
    let mut seen_urls = HashSet::new();

    while let Some(node) = queue.pop_front() {
        let Some(url) = node
            .select(&S_A)
            .next()
            .and_then(|a| a.value().attr("href"))
            .map(str::to_string)
        else {
            continue;
        };
        let thumbnail = node
            .select(&S_IMG)
            .next()
            .and_then(|i| i.value().attr("src"))
            .map(str::to_string);

        let tds: Vec<ElementRef<'_>> = node.select(&S_TD).collect();
        if tds.len() < 2 {
            continue;
        }
        let Some(g13) = tds[1].select(&S_DIV_DIV).next() else {
            continue;
        };
        let g13div: Vec<ElementRef<'_>> = g13.select(&S_DIV).collect();
        if g13div.len() < 5 {
            continue;
        }
        let article_type = el_text(g13div[0]).to_lowercase();
        let published = el_text(g13div[1]);
        let uploader = el_text(g13div[3]);
        let files = el_text(g13div[4]);

        let Some(gref) = tds[1].select(&S_DIV_A_DIV).next() else {
            continue;
        };
        let Some(title_el) = gref.select(&S_DIV).next() else {
            continue;
        };
        let title = el_text(title_el);

        let mut descript_keys = Vec::new();
        let mut descript_values = Vec::new();
        for tr in gref.select(&S_DIV_TABLE_TR) {
            let tr_tds: Vec<ElementRef<'_>> = tr.select(&S_TD).collect();
            if tr_tds.len() < 2 {
                continue;
            }
            let cont = el_text_trimmed(tr_tds[0]);
            if cont.is_empty() {
                continue;
            }
            let key = cont[..cont.len() - cont.chars().last().map_or(0, char::len_utf8)].to_string();
            let vals: Vec<String> = tr_tds[1].select(&S_DIV).map(el_text).collect();
            descript_keys.push(key);
            descript_values.push(vals);
        }

        if seen_urls.insert(url.clone()) {
            result.push(EhResultArticleParsed {
                url: Some(url),
                thumbnail,
                title: Some(title),
                uploader: Some(uploader),
                published: Some(published),
                files: Some(files),
                article_type: Some(article_type),
                descript_keys,
                descript_values,
            });
        }

        for tr in node.select(&S_TR) {
            queue.push_back(tr);
        }
    }

    result
}

#[flutter_rust_bridge::frb(sync)]
pub fn parse_eh_extended_list_view_sync(html: String) -> Vec<EhResultArticleParsed> {
    parse_eh_extended_list_view_inner(&html)
}

/// E-Hentai/ExHentai 확장 리스트 뷰 HTML을 백그라운드 워커 풀에서 파싱합니다.
pub fn parse_eh_extended_list_view(html: String) -> Vec<EhResultArticleParsed> {
    parse_eh_extended_list_view_inner(&html)
}

fn parse_eh_minimal_list_view_inner(html: &str) -> Vec<EhResultArticleParsed> {
    static S_TR: LazyLock<Selector> = LazyLock::new(|| sel("table.itg.gltm > tr"));
    static S_TD_DIV: LazyLock<Selector> = LazyLock::new(|| sel("td > div"));
    static S_IMG: LazyLock<Selector> = LazyLock::new(|| sel("img"));
    static S_TD: LazyLock<Selector> = LazyLock::new(|| sel("td"));
    static S_DIV: LazyLock<Selector> = LazyLock::new(|| sel("div"));
    static S_A: LazyLock<Selector> = LazyLock::new(|| sel("a"));
    static S_A_DIV: LazyLock<Selector> = LazyLock::new(|| sel("a div"));
    static S_DIV_A: LazyLock<Selector> = LazyLock::new(|| sel("div a"));

    let parsed = Html::parse_document(html);
    let mut nodes: Vec<ElementRef<'_>> = parsed.select(&S_TR).collect();
    if nodes.len() > 1 {
        nodes.remove(0);
    }

    let mut result = Vec::new();
    for el in nodes {
        let Some(type_el) = el.select(&S_TD_DIV).next() else {
            continue;
        };
        let article_type = el_text_trimmed(type_el).to_lowercase();
        let Some(img_el) = el.select(&S_IMG).next() else {
            continue;
        };
        let mut thumb = img_el.value().attr("src").map(str::to_string);
        if thumb.as_deref().is_some_and(|s| s.starts_with("data")) {
            thumb = img_el.value().attr("data-src").map(str::to_string);
        }
        let tds: Vec<ElementRef<'_>> = el.select(&S_TD).collect();
        if tds.len() < 6 {
            continue;
        }
        let td1_divs: Vec<ElementRef<'_>> = tds[1].select(&S_DIV).collect();
        if td1_divs.len() < 2 {
            continue;
        }
        let d1: Vec<ElementRef<'_>> = td1_divs[1].select(&S_DIV).collect();
        if d1.len() < 2 {
            continue;
        }
        let d1_0: Vec<ElementRef<'_>> = d1[1].select(&S_DIV).collect();
        if d1_0.len() < 2 {
            continue;
        }
        let published = d1_0[0]
            .select(&S_DIV)
            .nth(1)
            .map(el_text_trimmed)
            .unwrap_or_default();
        let files = d1_0[1]
            .select(&S_DIV)
            .nth(1)
            .map(el_text_trimmed)
            .unwrap_or_default();
        let url = tds[3]
            .select(&S_A)
            .next()
            .and_then(|a| a.value().attr("href"))
            .map(str::to_string);
        let title = tds[3].select(&S_A_DIV).next().map(el_text_trimmed);
        let uploader = tds[5].select(&S_DIV_A).next().map(el_text_trimmed);

        result.push(EhResultArticleParsed {
            url,
            thumbnail: thumb,
            title,
            uploader,
            published: Some(published),
            files: Some(files),
            article_type: Some(article_type),
            descript_keys: Vec::new(),
            descript_values: Vec::new(),
        });
    }
    result
}

#[flutter_rust_bridge::frb(sync)]
pub fn parse_eh_minimal_list_view_sync(html: String) -> Vec<EhResultArticleParsed> {
    parse_eh_minimal_list_view_inner(&html)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_hitomi_gallery_block_with_tags_and_language() {
        let html = r#"
<div class="dj">
<a href="/doujinshi/sample-4185588.html"><img data-src="//tn.gold-usergeneratedcontent.net/webpbigtn/2/20/sample.webp"></a>
<h1>Sample Work</h1>
<div class="artist-list"><ul><li><a href="/artist/nishi-all.html">nishi</a></li></ul></div>
<div class="dj-content">
<table class="dj-desc">
<tr><td>Series</td><td class="series-list"><a href="/series/s.html">Sample Series</a></td></tr>
<tr><td>Type</td><td><a href="/type/doujinshi-all.html">doujinshi</a></td></tr>
<tr><td>Language</td><td><a href="/index-korean.html">한국어</a></td></tr>
<tr><td>Tags</td><td class="relatedtags"><ul>
<li><a href="/tag/female%3Aamputee-all.html">amputee ♀</a></li>
<li><a href="/tag/male%3Aamputee-all.html">amputee ♂</a></li>
<li><a href="/tag/digital-all.html">digital</a></li>
</ul></td></tr>
</table>
</div>
</div>
"#;
        let parsed = parse_hitomi_gallery_block_inner(html).unwrap();
        assert_eq!(parsed.title, "Sample Work");
        assert_eq!(parsed.magic.as_deref(), Some("/doujinshi/sample-4185588.html"));
        assert_eq!(parsed.thumbnail.as_deref(), Some("webpbigtn/2/20/sample.webp"));
        assert_eq!(parsed.artists, vec!["nishi"]);
        assert_eq!(parsed.series, vec!["Sample Series"]);
        assert_eq!(parsed.article_type.as_deref(), Some("doujinshi"));
        assert_eq!(parsed.language.as_deref(), Some("korean"));
        assert_eq!(
            parsed.tags,
            vec!["female:amputee", "male:amputee", "digital"]
        );
    }

    #[test]
    fn parses_eh_extended_list_view_and_images_url() {
        let html = r#"
<table class="itg glte">
  <tr>
    <td><a href="https://exhentai.org/g/12345/abcdef1234/"><img src="https://ehgt.org/t/1.jpg"></a></td>
    <td>
      <div>
        <div><div>Doujinshi</div><div>2026-01-01 12:00</div><div></div><div>upuser</div><div>24 pages</div></div>
        <a href="https://exhentai.org/g/12345/abcdef1234/"><div>
          <div>Sample EH Title</div>
          <div><table>
            <tr><td>female:</td><td><div>sole female</div></td></tr>
            <tr><td>language:</td><td><div>korean</div><div>translated</div></td></tr>
          </table></div>
        </div></a>
      </div>
    </td>
  </tr>
</table>
"#;
        let list = parse_eh_extended_list_view_inner(html);
        assert_eq!(list.len(), 1);
        assert_eq!(list[0].title.as_deref(), Some("Sample EH Title"));
        assert_eq!(list[0].article_type.as_deref(), Some("doujinshi"));
        assert_eq!(list[0].uploader.as_deref(), Some("upuser"));
        assert_eq!(list[0].descript_keys, vec!["female", "language"]);
        assert_eq!(list[0].descript_values[0], vec!["sole female"]);

        let gdt = r#"<div id="gdt"><div><a href="https://exhentai.org/s/111/12345-1"></a></div></div>"#;
        assert_eq!(
            parse_eh_images_url_inner(gdt),
            vec!["https://exhentai.org/s/111/12345-1"]
        );
    }
}
