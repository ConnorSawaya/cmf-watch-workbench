#![cfg_attr(any(target_os="none",wp2_sim),no_main,cfg_attr(target_os="none",no_std))]
#[cfg(not(any(target_os="none",wp2_sim)))] fn main() {}
#[cfg(any(target_os="none",wp2_sim))] mod device {
 cmf_wp2_app::entry!(main);
 cmf_wp2_app::app_icon!();
 fn main(api:&'static cmf_wp2_app::Api)->i32 {cmf_workbench_tools::run(api,cmf_workbench_tools::Kind::Counter)}
}
